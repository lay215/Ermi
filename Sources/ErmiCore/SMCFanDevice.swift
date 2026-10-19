import Foundation
import Darwin

public enum SMCFanError: Error, CustomStringConvertible {
    case rejected(String)
    public var description: String { switch self { case .rejected(let reason): return reason } }
}

/// 仅helper实例能够写硬件；actor串行化解锁、目标写入及恢复，调用方不能指定SMC key。
public actor SMCFanDevice: FanDevice {
    private let transport: any SMCKeyWriting
    private let model: String
    private let cpu: String
    private let isRoot: @Sendable () -> Bool
    private let clock: @Sendable () -> Double
    private let pause: @Sendable (UInt32) -> Void
    private let journalURL: URL?
    private var owned: Set<Int> = []
    private var ownsUnlock = false
    private var loadedJournal = false

    public init() {
        transport = SMCReadOnlyTransport()
        model = Self.sysctl("hw.model"); cpu = Self.sysctl("machdep.cpu.brand_string")
        isRoot = { geteuid() == 0 }
        clock = { ProcessInfo.processInfo.systemUptime }
        pause = { usleep($0) }
        journalURL = URL(fileURLWithPath: "/var/db/app.ermi.fan-helper/ownership.json")
    }

    init(transport: any SMCKeyWriting, model: String = "MacBookPro18,4", cpu: String = "Apple M1 Max", isRoot: @escaping @Sendable () -> Bool = { true }, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }, pause: @escaping @Sendable (UInt32) -> Void = { _ in }, journalURL: URL? = nil) {
        self.transport = transport; self.model = model; self.cpu = cpu
        self.isRoot = isRoot; self.clock = clock; self.pause = pause; self.journalURL = journalURL
    }

    public func capabilities() throws -> [FanCapability] {
        try checkModel()
        let count = try number("FNum", type: "ui8 ", size: 1)
        guard count == 2 else { throw error("当前M1 Max配置要求两只可验证风扇") }
        return try (0..<2).map { index in
            let minimum = try rpm("F\(index)Mn")
            let maximum = try rpm("F\(index)Mx")
            guard minimum >= 0, maximum > minimum, maximum <= 30_000 else { throw error("风扇硬件转速范围无效") }
            _ = try modeKey(index)
            _ = try rpm("F\(index)Tg")
            let name = (try? transport.read("F\(index)ID").fanName) ?? "风扇 \(index + 1)"
            return FanCapability(index: index, name: name, minimumRPM: minimum, maximumRPM: maximum)
        }
    }

    public func snapshot() throws -> FanDeviceSnapshot {
        let capabilities = try capabilities()
        let states = try capabilities.map { fan in
            let key = try modeKey(fan.index)
            let mode = try modeValue(key)
            let actual = try rpm("F\(fan.index)Ac")
            guard (0...30_000).contains(actual) else { throw error("实测RPM无效") }
            return FanDeviceState(index: fan.index, mode: mode == 1 ? .manual : .system, targetRPM: try rpm("F\(fan.index)Tg"), actualRPM: actual)
        }
        let hardware = HardwareSensorReader(transport: transport, model: model, cpuBrand: cpu).sample()
        // 时间戳取本轮采样完成时的单调时钟，不能借用App传入的旧now伪装采样时间。
        return FanDeviceSnapshot(fans: states, cpuTemperature: hardware.cpuTemperature?.celsius, gpuTemperature: hardware.gpuTemperature?.celsius, sampledAt: clock())
    }

    public func setManualRPM(index: Int, rpm requested: Double) throws {
        try checkRoot()
        try ensureJournalLoaded()
        let fans = try capabilities()
        guard let fan = fans.first(where: { $0.index == index }), requested.isFinite,
              requested.rounded() == requested, (fan.minimumRPM...fan.maximumRPM).contains(requested) else { throw error("目标RPM超出本机硬件范围") }
        let modeKey = try modeKey(index)
        let originalMode = try modeValue(modeKey)
        let unlock: UInt8?
        do { unlock = try readByte("Ftst") }
        catch SMCReadError.missingKey { unlock = nil }
        guard owned.contains(index) || originalMode != 1 else { throw error("风扇已被其他控制器接管") }
        guard unlock != 1 || ownsUnlock else { throw error("Ftst已被其他控制器启用") }
        guard unlock == nil || unlock == 0 || unlock == 1 else { throw error("Ftst状态无效") }
        // 先落盘再写，进程在任何写步骤被终止后，下次helper仍知道哪些风扇需要恢复。
        owned.insert(index)
        try persistJournal()
        do {
            if originalMode != 1 {
                do { try writeByte(modeKey, 1); try confirmMode(modeKey, manual: true) }
                catch {
                    if Task.isCancelled { throw error }
                    // 本机macOS27的M1 Max没有Ftst；只允许已存在且类型核实的解锁key。
                    guard let unlock else { throw self.error("直接接管失败：\(error)；设备没有可验证的 Ftst 解锁键") }
                    if unlock == 0 {
                        ownsUnlock = true
                        try persistJournal()
                        try retry(attempts: 10, delay: 50_000) { try self.writeByte("Ftst", 1) }
                        pause(3_000_000)
                    }
                    try retry(attempts: 20, delay: 100_000) { try self.writeByte(modeKey, 1) }
                    try confirmMode(modeKey, manual: true)
                }
            }
            guard try modeValue(modeKey) == 1 else { throw error("手动模式未确认") }
            try retry(attempts: 3, delay: 50_000) { try self.writeRPM("F\(index)Tg", requested) }
            try confirmTarget("F\(index)Tg", requested: requested, modeKey: modeKey)
        } catch {
            // 保留journal与owned候选；外层控制器统一回滚所有已尝试的风扇。
            throw error
        }
    }

    public func restoreSystem(index: Int) throws {
        try checkRoot(); try ensureJournalLoaded(); try checkModel()
        guard owned.contains(index) else { return }
        let key = try modeKey(index)
        // 依据已核实的arm恢复协议先交还模式，再清目标；不得将Tg=0当作手动停转。
        try retry(attempts: 3, delay: 50_000, respectingCancellation: false) { try self.writeByte(key, 0) }
        try retry(attempts: 3, delay: 50_000, respectingCancellation: false) { try self.writeRPM("F\(index)Tg", 0) }
        try confirmMode(key, manual: false)
        let remaining = owned.subtracting([index])
        if remaining.isEmpty && ownsUnlock {
            try retry(attempts: 3, delay: 50_000, respectingCancellation: false) { try self.writeByte("Ftst", 0) }
            guard try readByte("Ftst") == 0 else { throw error("全局风扇控制尚未释放") }
            ownsUnlock = false
        }
        owned = remaining
        try persistJournal()
    }

    /// helper启动时调用；只恢复root日志中记录的上次接管，不抢其他App当前手动风扇。
    public func recoverPreviousSession() throws {
        try checkRoot(); try ensureJournalLoaded(); try checkModel()
        var failures: [String] = []
        for index in owned.sorted() {
            do { try restoreSystem(index: index) } catch { failures.append(String(describing: error)) }
        }
        if !failures.isEmpty { throw error(failures.joined(separator: "；")) }
    }

    private func modeKey(_ index: Int) throws -> String {
        guard (0..<2).contains(index) else { throw error("风扇编号无效") }
        // 只有缺失key才允许改大小写；驱动错误和未知类型不能被降级吞掉。
        let lower = "F\(index)md"
        do { _ = try readByte(lower); return lower }
        catch SMCReadError.missingKey { let upper = "F\(index)Md"; _ = try readByte(upper); return upper }
    }
    private func modeValue(_ key: String) throws -> UInt8 {
        let mode = try readByte(key)
        guard [0, 1, 3].contains(mode) else { throw error("未知SMC风扇模式") }
        return mode
    }
    private func confirmMode(_ key: String, manual: Bool) throws {
        // 驱动接受写请求不等于固件已完成切换；最多只读等待 450ms，不反复写入抢占。
        // 仍未确认时保留实际模式供诊断，调用方回滚；绝不带着未确认模式写目标转速。
        var observed: UInt8 = 0
        for attempt in 0..<10 {
            // 取消接管要尽快回滚，但恢复不能因上层任务取消而停止等待确认。
            if manual && Task.isCancelled { throw CancellationError() }
            observed = try modeValue(key)
            if manual ? observed == 1 : observed != 1 { return }
            if attempt < 9 { pause(50_000) }
        }
        throw error("\(manual ? "手动" : "系统")模式未确认：\(key) 写入=\(manual ? 1 : 0)，回读=\(observed)，等待450ms后仍未生效")
    }
    private func confirmTarget(_ key: String, requested: Double, modeKey: String) throws {
        // 目标值和模式一样可能延迟更新；只轮询不重复写，避免掩盖其他控制器覆盖。
        // 等待中若丢失手动模式立即失败。这里确认的是目标寄存器，不是机械转速。
        var observed: Double = 0
        for attempt in 0..<10 {
            if Task.isCancelled { throw CancellationError() }
            let mode = try modeValue(modeKey)
            guard mode == 1 else { throw error("目标确认期间手动模式丢失：\(modeKey) 回读=\(mode)") }
            observed = try rpm(key)
            if abs(observed - requested) <= 1 { return }
            if attempt < 9 { pause(50_000) }
        }
        throw error("目标RPM回读不一致：\(key) 写入=\(requested)，回读=\(observed)，等待450ms后仍未生效")
    }
    private func readByte(_ key: String) throws -> UInt8 { UInt8(try number(key, type: "ui8 ", size: 1)) }
    private func number(_ key: String, type: String, size: Int) throws -> Double {
        let value = try transport.read(key)
        guard value.type == type, value.bytes.count == size, let number = value.number else { throw error("\(key)类型或长度不受支持") }
        return number
    }
    private func rpm(_ key: String) throws -> Double {
        let value = try transport.read(key)
        guard (value.type == "flt " && value.bytes.count == 4) || (value.type == "fpe2" && value.bytes.count == 2),
              let result = value.number, result >= 0, result <= 30_000 else { throw error("\(key)转速格式无效") }
        return result
    }
    private func writeByte(_ key: String, _ byte: UInt8) throws {
        _ = try readByte(key)
        try transport.write(SMCValue(key: key, type: "ui8 ", bytes: [byte]))
    }
    private func writeRPM(_ key: String, _ rpm: Double) throws {
        let current = try transport.read(key)
        _ = try self.rpm(key)
        let bytes: [UInt8]
        if current.type == "flt " {
            let bits = Float(rpm).bitPattern
            bytes = (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }
        } else {
            guard rpm <= 16383 else { throw error("fpe2转速超出编码范围") }
            let encoded = UInt16(rpm * 4)
            bytes = [UInt8(encoded >> 8), UInt8(encoded & 255)]
        }
        try transport.write(SMCValue(key: key, type: current.type, bytes: bytes))
    }
    private func retry(attempts: Int, delay: UInt32, respectingCancellation: Bool = true, operation: () throws -> Void) throws {
        var last: Error = error("写入失败")
        for attempt in 0..<attempts {
            // 主任务取消不能阻止交还系统控制；仅接管/调速重试响应取消。
            if respectingCancellation && Task.isCancelled { throw CancellationError() }
            do { try operation(); return } catch { last = error }
            if attempt + 1 < attempts { pause(delay) }
        }
        throw last
    }
    private func checkRoot() throws { guard isRoot() else { throw error("风扇写入需要已授权的root辅助服务") } }
    private func checkModel() throws { guard cpu == "Apple M1 Max", ["MacBookPro18,2", "MacBookPro18,4"].contains(model) else { throw error("尚未验证该机型的风扇写入协议") } }
    private func error(_ text: String) -> SMCFanError { .rejected(text) }
    private static func sysctl(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private struct Journal: Codable { let indices: [Int]; let unlock: Bool }
    private func ensureJournalLoaded() throws {
        guard !loadedJournal else { return }
        guard let url = journalURL else { loadedJournal = true; return }
        try secureDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw error("不能读取恢复日志") }
            loadedJournal = true; return
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 4096 else { throw error("恢复日志权限或大小无效") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw error("恢复日志读取不完整") }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(bytes))
        guard journal.indices.allSatisfy({ (0..<2).contains($0) }), Set(journal.indices).count == journal.indices.count,
              !journal.unlock || !journal.indices.isEmpty else { throw error("恢复日志内容无效") }
        owned = Set(journal.indices); ownsUnlock = journal.unlock; loadedJournal = true
    }
    private func secureDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw error("不能创建恢复日志目录") }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw error("恢复日志目录必须由root独占") }
    }
    private func persistJournal() throws {
        guard let url = journalURL else { return }
        try secureDirectory(url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(Journal(indices: owned.sorted(), unlock: ownsUnlock))
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".ownership-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error("不能写入恢复日志") }
        defer { close(fd); unlink(temporary.path) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw error("恢复日志未能持久化") }
        let dirFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { throw error("不能同步恢复日志目录") }
        defer { close(dirFD) }
        guard fsync(dirFD) == 0 else { throw error("恢复日志目录未能持久化") }
    }
}
