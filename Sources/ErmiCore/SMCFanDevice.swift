import Foundation
import Darwin

public enum SMCFanError: Error, CustomStringConvertible {
    case rejected(String)
    public var description: String { switch self { case .rejected(let reason): return reason } }
}

/// 仅helper实例能够写硬件；actor串行化解锁、目标写入及恢复，写入 key 始终由设备内部决定。
public actor SMCFanDevice: FanDevice {
    private let transport: any SMCKeyWriting
    private let model: String
    private let cpu: String
    private let isRoot: @Sendable () -> Bool
    private let clock: @Sendable () -> Double
    private let pause: @Sendable (UInt32) -> Void
    private let journalURL: URL?
    private var journalReader: (() throws -> Data?)?
    private var journalWriter: ((Data) throws -> Void)?
    private var owned: Set<Int> = []
    private var ownsUnlock = false
    private var ownedRoutes: [Int: ModeRoute] = [:]
    private var loadedJournal = false

    public init() {
        transport = SMCReadOnlyTransport()
        model = Self.sysctl("hw.model"); cpu = Self.sysctl("machdep.cpu.brand_string")
        isRoot = { geteuid() == 0 }
        clock = { ProcessInfo.processInfo.systemUptime }
        pause = { usleep($0) }
        journalURL = URL(fileURLWithPath: "/var/db/app.ermi.fan-helper/ownership.json")
    }

    init(transport: any SMCKeyWriting, model: String = "MacBookPro18,4", cpu: String = "Apple M1 Max", isRoot: @escaping @Sendable () -> Bool = { true }, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }, pause: @escaping @Sendable (UInt32) -> Void = { _ in }, journalURL: URL? = nil, journalReader: (() throws -> Data?)? = nil, journalWriter: ((Data) throws -> Void)? = nil) {
        self.transport = transport; self.model = model; self.cpu = cpu
        self.isRoot = isRoot; self.clock = clock; self.pause = pause; self.journalURL = journalURL
        self.journalReader = journalReader; self.journalWriter = journalWriter
    }

    public func capabilities() throws -> [FanCapability] {
        let count = try fanCount()
        // FNum=0 是无风扇硬件；单字符风扇键只覆盖 0...9，不能截断更多风扇后误报成功。
        return try (0..<count).map { index in
            let minimum = try rpm("F\(index)Mn")
            let maximum = try rpm("F\(index)Mx")
            guard minimum >= 0, maximum > minimum, maximum <= 30_000 else { throw error("风扇硬件转速范围无效") }
            _ = try modeValue(modeKey(index))
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

    public func snapshot(sensorKey: String?) async throws -> FanDeviceSnapshot {
        let ordinary = try snapshot()
        guard let sensorKey, FanThermalRule.isValidSensorKey(sensorKey) else { return ordinary }
        // helper 只在本轮普通快照之后读取选中键，不枚举候选、不复用 App 读数，也不回退 CPU/GPU。
        // 缺失、类型错误或越界值省略，由控制器拒绝；恢复路径始终不依赖温度。
        let temperature = try? transport.read(sensorKey).temperatureCelsius
        return FanDeviceSnapshot(fans: ordinary.fans, cpuTemperature: ordinary.cpuTemperature,
                                 gpuTemperature: ordinary.gpuTemperature, sampledAt: clock(),
                                 sensorTemperatures: temperature.map { [sensorKey: $0] } ?? [:])
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
        do { unlock = modeKey.mask ? nil : try readByte("Ftst") }
        catch SMCReadError.missingKey { unlock = nil }
        guard owned.contains(index) || originalMode != 1 else { throw error("风扇已被其他控制器接管") }
        guard unlock != 1 || ownsUnlock else { throw error("Ftst已被其他控制器启用") }
        guard unlock == nil || unlock == 0 || unlock == 1 else { throw error("Ftst状态无效") }
        // 先落盘再写，进程在任何写步骤被终止后，下次helper仍知道哪些风扇需要恢复。
        owned.insert(index)
        ownedRoutes[index] = modeKey
        try persistJournal()
        do {
            if originalMode != 1 {
                do { try writeMode(modeKey, manual: true); try confirmMode(modeKey, manual: true) }
                catch {
                    if Task.isCancelled { throw error }
                    // 本机macOS27的M1 Max没有Ftst；只允许已存在且类型核实的解锁key。
                    if modeKey.mask { throw error }
                    guard let unlock else { throw self.error("直接接管失败：\(error)；设备没有可验证的 Ftst 解锁键") }
                    if unlock == 0 {
                        ownsUnlock = true
                        try persistJournal()
                        try retry(attempts: 10, delay: 50_000) { try self.writeByte("Ftst", 1) }
                        pause(3_000_000)
                    }
                    try retry(attempts: 20, delay: 100_000) { try self.writeMode(modeKey, manual: true) }
                    try confirmMode(modeKey, manual: true)
                }
            }
            guard try modeConfirmed(modeKey, manual: true) else { throw error("手动模式未确认") }
            try retry(attempts: 3, delay: 50_000) { try self.writeRPM("F\(index)Tg", requested) }
            try confirmTarget("F\(index)Tg", requested: requested, modeKey: modeKey)
        } catch {
            // 保留journal与owned候选；外层控制器统一回滚所有已尝试的风扇。
            throw error
        }
    }

    public func restoreSystem(index: Int) throws {
        try checkRoot(); try ensureJournalLoaded()
        guard owned.contains(index) else { return }
        guard (0..<(try fanCount())).contains(index) else { throw error("恢复日志风扇编号不属于当前硬件") }
        let current = try modeKey(index)
        let key = ownedRoutes[index] ?? current
        guard key == current else { throw error("恢复日志协议与当前硬件不一致") }
        // 依据已核实的arm恢复协议先交还模式，再清目标；不得将Tg=0当作手动停转。
        try retry(attempts: 3, delay: 50_000, respectingCancellation: false) { try self.writeMode(key, manual: false) }
        try confirmMode(key, manual: false)
        if key.clearTarget {
            try retry(attempts: 3, delay: 50_000, respectingCancellation: false) { try self.writeRPM("F\(index)Tg", 0) }
        }
        let remaining = owned.subtracting([index])
        if remaining.isEmpty && ownsUnlock {
            try retry(attempts: 3, delay: 50_000, respectingCancellation: false) { try self.writeByte("Ftst", 0) }
            guard try readByte("Ftst") == 0 else { throw error("全局风扇控制尚未释放") }
            ownsUnlock = false
        }
        let previousRoutes = ownedRoutes
        owned = remaining
        ownedRoutes.removeValue(forKey: index)
        do { try persistJournal() }
        catch {
            // 落盘失败时仍保留恢复候选，下次重试不能因为内存先清空而遗漏磁盘日志。
            owned.insert(index); ownedRoutes = previousRoutes
            throw error
        }
    }

    /// helper启动时调用；只恢复root日志中记录的上次接管，不抢其他App当前手动风扇。
    public func recoverPreviousSession() throws {
        try checkRoot(); try ensureJournalLoaded()
        var failures: [String] = []
        for index in owned.sorted() {
            do { try restoreSystem(index: index) } catch { failures.append(String(describing: error)) }
        }
        if !failures.isEmpty { throw error(failures.joined(separator: "；")) }
    }

    private struct ModeRoute: Codable, Equatable {
        let index: Int
        let key: String?
        let mask: Bool
        let clearTarget: Bool
    }
    private func fanCount() throws -> Int {
        let count = try number("FNum", type: "ui8 ", size: 1)
        guard (0...10).contains(count) else { throw error("风扇数量超出已验证的单字符 SMC 协议范围") }
        return Int(count)
    }
    private func modeKey(_ index: Int) throws -> ModeRoute {
        guard (0..<(try fanCount())).contains(index) else { throw error("风扇编号无效") }
        // 上游按架构区分协议：Intel 同时维护可选 Md 与 FS!；Apple Silicon 不使用 FS!。
        // CPU 品牌只选择协议族，具体键、类型、长度和状态仍必须逐项探测；未知族不写入。
        if cpu.contains("Intel") {
            _ = try maskValue()
            let key = "F\(index)Md"
            do { _ = try readModeByte(key); return ModeRoute(index: index, key: key, mask: true, clearTarget: false) }
            catch SMCReadError.missingKey { return ModeRoute(index: index, key: nil, mask: true, clearTarget: false) }
        }
        guard cpu.hasPrefix("Apple M") else { throw error("未知 CPU 架构的风扇写入协议") }
        // 只有缺失 key 才改大小写；驱动错误或格式未知都不能触发协议回退。
        let lower = "F\(index)md", upper = "F\(index)Md"
        do { _ = try readModeByte(lower); return ModeRoute(index: index, key: lower, mask: false, clearTarget: true) }
        catch SMCReadError.missingKey {
            _ = try readModeByte(upper)
            return ModeRoute(index: index, key: upper, mask: false, clearTarget: true)
        }
    }
    private func readModeByte(_ key: String) throws -> UInt8 {
        let mode = try readByte(key)
        guard [0, 1, 3].contains(mode) else { throw error("未知SMC风扇模式") }
        return mode
    }
    private func maskValue() throws -> UInt16 { UInt16(try number("FS! ", type: "ui16", size: 2)) }
    private func modeValue(_ route: ModeRoute) throws -> UInt8 {
        let individual = try route.key.map { try readModeByte($0) } ?? 0
        let maskManual = try route.mask && maskValue() & (UInt16(1) << route.index) != 0
        // 任一控制寄存器为 manual 都视为已接管，避免双寄存器不同步时抢其他控制器。
        return individual == 1 || maskManual ? 1 : individual
    }
    private func modeConfirmed(_ route: ModeRoute, manual: Bool) throws -> Bool {
        let individual = try route.key.map { try readModeByte($0) }
        let maskManual: Bool? = try route.mask ? maskValue() & (UInt16(1) << route.index) != 0 : nil
        return (individual.map { manual ? $0 == 1 : $0 != 1 } ?? true) && (maskManual.map { $0 == manual } ?? true)
    }
    private func writeMode(_ route: ModeRoute, manual: Bool) throws {
        if let key = route.key { try writeByte(key, manual ? 1 : 0) }
        if route.mask {
            // FS! 是大端 ui16 位掩码：每次读取最新值，只修改自己这只风扇的位。
            let current = try maskValue(), bit = UInt16(1) << route.index
            let next = manual ? current | bit : current & ~bit
            if next != current { try transport.write(SMCValue(key: "FS! ", type: "ui16", bytes: [UInt8(next >> 8), UInt8(next & 255)])) }
        }
    }
    private func confirmMode(_ key: ModeRoute, manual: Bool) throws {
        // 驱动接受写请求不等于固件已完成切换；最多只读等待 450ms，不反复写入抢占。
        // 仍未确认时保留实际模式供诊断，调用方回滚；绝不带着未确认模式写目标转速。
        var observed: UInt8 = 0
        for attempt in 0..<10 {
            // 取消接管要尽快回滚，但恢复不能因上层任务取消而停止等待确认。
            if manual && Task.isCancelled { throw CancellationError() }
            observed = try modeValue(key)
            if try modeConfirmed(key, manual: manual) { return }
            if attempt < 9 { pause(50_000) }
        }
        throw error("\(manual ? "手动" : "系统")模式未确认：\(key) 写入=\(manual ? 1 : 0)，回读=\(observed)，等待450ms后仍未生效")
    }
    private func confirmTarget(_ key: String, requested: Double, modeKey: ModeRoute) throws {
        // 目标值和模式一样可能延迟更新；只轮询不重复写，避免掩盖其他控制器覆盖。
        // 等待中若丢失手动模式立即失败。这里确认的是目标寄存器，不是机械转速。
        var observed: Double = 0
        for attempt in 0..<10 {
            if Task.isCancelled { throw CancellationError() }
            let mode = try modeValue(modeKey)
            guard try modeConfirmed(modeKey, manual: true) else { throw error("目标确认期间手动模式丢失：\(modeKey) 回读=\(mode)") }
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
    private func error(_ text: String) -> SMCFanError { .rejected(text) }
    private static func sysctl(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private struct Journal: Codable { let indices: [Int]; let unlock: Bool; let routes: [Int: ModeRoute]? }
    private func ensureJournalLoaded() throws {
        guard !loadedJournal else { return }
        // 内部测试可注入存储故障；生产入口始终走下方 root 独占文件校验。
        if let journalReader {
            if let data = try journalReader() { try loadJournal(data) }
            loadedJournal = true; return
        }
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
        try loadJournal(Data(bytes))
    }
    private func loadJournal(_ data: Data) throws {
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        guard journal.indices.allSatisfy({ (0..<10).contains($0) }), Set(journal.indices).count == journal.indices.count,
              !journal.unlock || !journal.indices.isEmpty else { throw error("恢复日志内容无效") }
        if let routes = journal.routes {
            guard Set(routes.keys) == Set(journal.indices), routes.allSatisfy({ index, route in
                route.index == index && (route.mask ? !route.clearTarget && (route.key == nil || route.key == "F\(index)Md") : route.clearTarget && (route.key == "F\(index)Md" || route.key == "F\(index)md"))
            }) else { throw error("恢复日志协议无效") }
            ownedRoutes = routes
        }
        else {
            // 旧日志仅来自 M1 Max per-fan 协议；禁止将旧所有权套到 Intel 掩码上。
            for index in journal.indices {
                let route = try modeKey(index)
                guard !route.mask else { throw error("旧恢复日志不能用于不同的风扇协议") }
                ownedRoutes[index] = route
            }
        }
        // 所有协议验证完才发布恢复状态，失败保留磁盘日志供诊断。
        owned = Set(journal.indices); ownsUnlock = journal.unlock; loadedJournal = true
    }
    private func secureDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw error("不能创建恢复日志目录") }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw error("恢复日志目录必须由root独占") }
    }
    private func persistJournal() throws {
        let data = try JSONEncoder().encode(Journal(indices: owned.sorted(), unlock: ownsUnlock, routes: ownedRoutes))
        if let journalWriter { try journalWriter(data); return }
        guard let url = journalURL else { return }
        try secureDirectory(url.deletingLastPathComponent())
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
