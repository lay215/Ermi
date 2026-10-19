import Foundation

public struct ProcessIdentity: Hashable, Sendable, Codable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public struct ProcessSample: Identifiable, Sendable, Codable {
    public let id: ProcessIdentity
    public let name: String
    public let cpuPercent: Double?
    public let memoryBytes: UInt64
    public let parentPID: Int32
    public var pid: Int32 { id.pid }
}

public struct MemorySample: Sendable, Codable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let compressedBytes: UInt64
    public let wiredBytes: UInt64
    public var usedPercent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }
}

public struct HistoryPoint: Identifiable, Sendable, Codable {
    public let timestamp: Date
    public let cpuPercent: Double?
    public let memoryPercent: Double?
    public var id: Date { timestamp }
}

public enum ThermalState: String, Sendable, Codable {
    case nominal, fair, serious, critical, unknown
}

public struct SystemSnapshot: Sendable, Codable {
    public let timestamp: Date
    public let cpuPercent: Double?
    public let memory: MemorySample?
    public let processes: [ProcessSample]
    public let history: [HistoryPoint]
    public let logicalCPUCount: Int
    public let thermalState: ThermalState
    public let hardware: HardwareSnapshot
    public let disk: DiskSample?
    public let battery: BatterySample?
    public let network: NetworkSample?
    public let memoryPressure: MemoryPressure?
    public let bootTime: Date?
    public let hardwareModel: String?

    // 可选扩展保证预览和旧调用仍能构造快照；缺失读数不代表零值。
    public init(timestamp: Date, cpuPercent: Double?, memory: MemorySample?, processes: [ProcessSample], history: [HistoryPoint], logicalCPUCount: Int, thermalState: ThermalState, hardware: HardwareSnapshot, disk: DiskSample? = nil, battery: BatterySample? = nil, network: NetworkSample? = nil, memoryPressure: MemoryPressure? = nil, bootTime: Date? = nil, hardwareModel: String? = nil) {
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.processes = processes
        self.history = history
        self.logicalCPUCount = logicalCPUCount
        self.thermalState = thermalState
        self.hardware = hardware
        self.disk = disk
        self.battery = battery
        self.network = network
        self.memoryPressure = memoryPressure
        self.bootTime = bootTime
        self.hardwareModel = hardwareModel
    }
}

// 差分公式独立于系统调用，便于验证首帧、计数回退和多核口径。
enum SampleMath {
    static func cpuPercent(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == 4, current.count == 4 else { return nil }
        // Mach natural_t 计数允许溢出；使用无符号模运算跨越单次回绕。
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) * 100
    }

    static func processPercent(previous: UInt64, current: UInt64, elapsed: Double, timebaseNumer: UInt32 = 1, timebaseDenom: UInt32 = 1) -> Double? {
        guard current >= previous, elapsed > 0, elapsed.isFinite, timebaseDenom > 0 else { return nil }
        // libproc rusage CPU 时间沿用 Mach timebase，Apple Silicon 不能把 tick 当纳秒。
        // 先按 numer/denom 转纳秒，一个核心占满记为 100%，多线程允许超过 100%。
        return Double(current - previous) * Double(timebaseNumer) / Double(timebaseDenom) / 1_000_000_000 / elapsed * 100
    }

    static func usedMemory(active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, purgeable: UInt64, external: UInt64, pageSize: UInt64, total: UInt64) -> UInt64 {
        // 活跃/非活跃页中扣除可清理和文件缓存，再加 wired 与压缩器实际物理页。
        // 这是 VM 页构成估计，不把空闲内存当成“已用”，也不重复计入 speculative/free。
        let reclaimable = purgeable + external
        let pageable = active + inactive
        let appPages = pageable > reclaimable ? pageable - reclaimable : 0
        return min(total, (appPages + wired + compressed) * pageSize)
    }
}

import Darwin
