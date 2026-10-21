import Foundation
import Darwin

public actor SystemSampler {
    private let hardwareReader = HardwareSensorReader()
    private var metricsReader = SystemMetricsReader()
    private var previousTicks: [UInt32]?
    private var timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private var previousProcesses: [ProcessIdentity: (cpu: UInt64, uptime: Double)] = [:]
    private var history: [HistoryPoint] = []

    public init() {}

    public func sample(includeTemperatureSensors: Bool = false) -> SystemSnapshot {
        let timestamp = Date()
        let cpu: Double?
        if let ticks = readTicks() {
            cpu = previousTicks.flatMap { SampleMath.cpuPercent(previous: $0, current: ticks) }
            previousTicks = ticks
        } else {
            cpu = nil
            previousTicks = nil
        }
        let memory = readMemory()
        let processes = readProcesses()
        history.append(HistoryPoint(timestamp: timestamp, cpuPercent: cpu, memoryPercent: memory?.usedPercent))
        // 仅保留最近一分钟；睡眠唤醒不会把过期样本当成当前趋势。
        history.removeAll { $0.timestamp < timestamp.addingTimeInterval(-60) }
        return SystemSnapshot(timestamp: timestamp, cpuPercent: cpu, memory: memory, processes: processes, history: history, logicalCPUCount: ProcessInfo.processInfo.activeProcessorCount, thermalState: thermalState(), hardware: hardwareReader.sample(includeTemperatureSensors: includeTemperatureSensors), disk: SystemMetricsReader.readDisk(), battery: SystemMetricsReader.readBattery(), network: metricsReader.readNetwork(), memoryPressure: SystemMetricsReader.readMemoryPressure(), bootTime: SystemMetricsReader.readBootTime(), hardwareModel: SystemMetricsReader.readHardwareModel())
    }

    // 操作前重读启动时间，避免 PID 回收后把用户选中的旧进程误认成新进程。
    public func identity(for pid: Int32) -> ProcessIdentity? {
        guard let info = bsdInfo(pid), info.pbi_uid == getuid() else { return nil }
        return identity(pid, info)
    }

    func protectedProcessIDs() throws -> Set<Int32> {
        var current = getpid()
        var result: Set<Int32> = [0, 1]
        while current > 1 {
            guard result.insert(current).inserted else { throw ProcessSignalError.unverifiableAncestry }
            guard let info = bsdInfo(current) else { throw ProcessSignalError.unverifiableAncestry }
            current = Int32(info.pbi_ppid)
        }
        return result
    }

    private func identity(_ pid: Int32, _ info: proc_bsdinfo) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return nil }
        return info
    }

    private func readTicks() -> [UInt32]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    private func readMemory() -> MemorySample? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let total = ProcessInfo.processInfo.physicalMemory
        var kernelPageSize: vm_size_t = 0
        guard host_page_size(host, &kernelPageSize) == KERN_SUCCESS else { return nil }
        let page = UInt64(kernelPageSize)
        let used = SampleMath.usedMemory(active: UInt64(info.active_count), inactive: UInt64(info.inactive_count), wired: UInt64(info.wire_count), compressed: UInt64(info.compressor_page_count), purgeable: UInt64(info.purgeable_count), external: UInt64(info.external_page_count), pageSize: page, total: total)
        return MemorySample(totalBytes: total, usedBytes: used, compressedBytes: UInt64(info.compressor_page_count) * page, wiredBytes: UInt64(info.wire_count) * page)
    }

    private func readProcesses() -> [ProcessSample] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { previousProcesses = [:]; return [] }
        // 枚举期间进程数量会变化，预留空间；本轮消失或无权限的进程直接跳过。
        var pids = [Int32](repeating: 0, count: Int(estimated) + 128)
        let bytes = pids.count * MemoryLayout<Int32>.size
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32(bytes)) }
        guard count > 0 else { previousProcesses = [:]; return [] }
        var next: [ProcessIdentity: (cpu: UInt64, uptime: Double)] = [:]
        var result: [ProcessSample] = []
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            guard let info = bsdInfo(pid), info.pbi_uid == getuid() else { continue }
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else { continue }
            // 采样中进程也可能退出后复用 PID，二次核对后才接受本轮读数。
            let id = identity(pid, info)
            guard let after = bsdInfo(pid), identity(pid, after) == id, after.pbi_uid == getuid() else { continue }
            let uptime = ProcessInfo.processInfo.systemUptime
            let cpuTime = usage.ri_user_time + usage.ri_system_time
            let percent = previousProcesses[id].flatMap { SampleMath.processPercent(previous: $0.cpu, current: cpuTime, elapsed: uptime - $0.uptime, timebaseNumer: timebase.numer, timebaseDenom: timebase.denom) }
            next[id] = (cpuTime, uptime)
            var buffer = [CChar](repeating: 0, count: 1024)
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            let name = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self).trimmingCharacters(in: .controlCharacters) : "PID \(pid)"
            result.append(ProcessSample(id: id, name: name, cpuPercent: percent, memoryBytes: usage.ri_phys_footprint, parentPID: Int32(info.pbi_ppid)))
        }
        previousProcesses = next
        return result.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    private func thermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}
