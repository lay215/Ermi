import Foundation

public struct FanCapability: Sendable, Codable, Equatable {
    public let index: Int
    public let name: String
    public let minimumRPM: Double
    public let maximumRPM: Double
    public init(index: Int, name: String, minimumRPM: Double, maximumRPM: Double) {
        self.index = index; self.name = name; self.minimumRPM = minimumRPM; self.maximumRPM = maximumRPM
    }
}

public enum FanDeviceMode: String, Sendable, Codable { case system, manual }
public struct FanDeviceState: Sendable, Codable, Equatable {
    public let index: Int
    public let mode: FanDeviceMode
    public let targetRPM: Double?
    public let actualRPM: Double?
    public init(index: Int, mode: FanDeviceMode, targetRPM: Double?, actualRPM: Double?) {
        self.index = index; self.mode = mode; self.targetRPM = targetRPM; self.actualRPM = actualRPM
    }
}

public struct FanDeviceSnapshot: Sendable, Codable {
    public let fans: [FanDeviceState]
    public let cpuTemperature: Double?
    public let gpuTemperature: Double?
    public let sampledAt: Double
    public let sensorTemperatures: [String: Double]
    public init(fans: [FanDeviceState], cpuTemperature: Double?, gpuTemperature: Double?, sampledAt: Double, sensorTemperatures: [String: Double] = [:]) {
        self.fans = fans; self.cpuTemperature = cpuTemperature; self.gpuTemperature = gpuTemperature; self.sampledAt = sampledAt
        self.sensorTemperatures = sensorTemperatures
    }
}

/// 设备实现负责串行的单风扇模式/目标写入；控制器另行回读确认，实测RPM允许有机械响应延迟。
public protocol FanDevice: Sendable {
    func capabilities() async throws -> [FanCapability]
    func snapshot() async throws -> FanDeviceSnapshot
    func snapshot(sensorKey: String?) async throws -> FanDeviceSnapshot
    func setManualRPM(index: Int, rpm: Double) async throws
    func restoreSystem(index: Int) async throws
}

public extension FanDevice {
    // 保持既有设备实现兼容；未实现定向读取的设备会因缺少具体温度而安全拒绝温控。
    func snapshot(sensorKey: String?) async throws -> FanDeviceSnapshot { try await snapshot() }
}

public enum FanTemperatureSource: String, Sendable, Codable { case cpu, gpu, maxCPUAndGPU, sensor }
public struct FanThermalRule: Sendable, Codable, Equatable {
    public var sensor: FanTemperatureSource
    public var lowerTemperature: Double
    public var upperTemperature: Double
    public var lowerRPM: Double?
    public var upperRPM: Double?
    public var rampRPMPerSecond: Double?
    public var sensorKey: String?
    public init(sensor: FanTemperatureSource, lowerTemperature: Double, upperTemperature: Double, lowerRPM: Double? = nil, upperRPM: Double? = nil, rampRPMPerSecond: Double? = nil, sensorKey: String? = nil) {
        self.sensor = sensor; self.lowerTemperature = lowerTemperature; self.upperTemperature = upperTemperature
        self.lowerRPM = lowerRPM; self.upperRPM = upperRPM; self.rampRPMPerSecond = rampRPMPerSecond
        self.sensorKey = sensorKey
    }
    public static func isValidSensorKey(_ key: String) -> Bool {
        // SMC温度键固定为四字节ASCII，首字节必须为T，其余仅允许英文字母和数字。
        let bytes = Array(key.utf8)
        return bytes.count == 4 && bytes.first == 84 && bytes.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
    var hasValidSensorSelection: Bool {
        // 旧策略不能夹带具体键，避免新旧helper对同一预设产生不同解释。
        sensor == .sensor ? sensorKey.map(Self.isValidSensorKey) == true : sensorKey == nil
    }
}
public struct FanRPMTarget: Sendable, Codable, Equatable {
    public let index: Int
    public let rpm: Double
    public init(index: Int, rpm: Double) { self.index = index; self.rpm = rpm }
}
public enum FanControlConfiguration: Sendable, Codable, Equatable {
    case fixed(rpm: Double)
    case fixedTargets([FanRPMTarget])
    case thermal(FanThermalRule)
}
public struct FanPreset: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var configuration: FanControlConfiguration
    public init(id: UUID = UUID(), name: String, configuration: FanControlConfiguration) {
        self.id = id; self.name = name; self.configuration = configuration
    }
}
public enum FanControlPhase: String, Sendable, Codable { case system, applied, needsRecovery, failed }
public struct FanControlStatus: Sendable, Codable, Equatable {
    public let phase: FanControlPhase
    public let preset: FanPreset?
    public let targets: [Int: Double]
    public let recoveryIndices: [Int]
    public let message: String?
    public init(phase: FanControlPhase, preset: FanPreset? = nil, targets: [Int: Double] = [:], recoveryIndices: [Int] = [], message: String? = nil) {
        self.phase = phase; self.preset = preset; self.targets = targets; self.recoveryIndices = recoveryIndices; self.message = message
    }
}

private enum FanControlError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let text): return text } }
}

/// helper以单调时钟驱动tick；客户端心跳仅续租，启动与加载预设均不接管硬件。
public actor FanController {
    private let device: any FanDevice
    private let leaseDuration: Double
    private let sensorMaximumAge: Double
    private let clock: @Sendable () -> Double
    private var current = FanControlStatus(phase: .system)
    private var owned: Set<Int> = []
    private var leaseID: UUID?
    private var lastHeartbeat: Double?
    private var lastTick: Double?
    private var busy = false
    private var recoveryRequested = false
    private var recoveryWaiters: [CheckedContinuation<FanControlStatus, Never>] = []

    public init(device: any FanDevice, leaseDuration: Double = 10, sensorMaximumAge: Double = 10, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.device = device
        self.clock = clock
        self.leaseDuration = leaseDuration.isFinite && leaseDuration > 0 ? leaseDuration : 10
        self.sensorMaximumAge = sensorMaximumAge.isFinite && sensorMaximumAge > 0 ? sensorMaximumAge : 10
    }
    public func status() -> FanControlStatus { current }
    public func heartbeat(leaseID: UUID, now: Double) -> Bool {
        guard self.leaseID == leaseID, now.isFinite, let previous = lastHeartbeat, now >= previous,
              now - previous <= leaseDuration, !recoveryRequested else { return false }
        lastHeartbeat = now
        return true
    }

    public func apply(_ preset: FanPreset, leaseID: UUID, now: Double) async -> FanControlStatus {
        guard !busy else { return current }
        busy = true
        defer { finishOperation() }
        if recoveryRequested || current.phase == .needsRecovery { return await recover(reason: "需先恢复上次未完成的接管") }
        do {
            guard now.isFinite else { throw FanControlError.invalid("控制时钟无效") }
            // 首个await前建立租约，设备调用期间的有效心跳不能被旧的调用起点覆盖。
            self.leaseID = leaseID; lastHeartbeat = now
            let capabilities = try await checkedCapabilities()
            let snapshot = try await device.snapshot(sensorKey: requestedSensorKey(for: preset.configuration))
            // 在任何写入候选登记前检查已有控制，避免把别人的manual误记为我们的待恢复风扇。
            guard capabilities.allSatisfy({ fan in
                let states = snapshot.fans.filter { $0.index == fan.index }
                return states.count == 1 && (states[0].mode == .system || owned.contains(fan.index))
            }) else { throw FanControlError.invalid("风扇已被其他控制器接管，或模式不可确认") }
            let sampledNow = try operationTime(startedAt: now)
            let targets = try makeTargets(preset.configuration, capabilities: capabilities, snapshot: snapshot, now: sampledNow, ramp: false)
            if recoveryRequested { return await recover(reason: nil) }
            // 新预设显式应用后才换租约；先前已接管的风扇仍纳入失败恢复范围。
            try checkLease(now: sampledNow)
            try await writeAndConfirm(targets)
            if recoveryRequested { return await recover(reason: "已请求恢复系统控制") }
            let confirmedNow = try operationTime(startedAt: now)
            try checkLease(now: confirmedNow)
            lastTick = confirmedNow
            current = FanControlStatus(phase: .applied, preset: preset, targets: targets)
        } catch {
            return await recover(reason: String(describing: error))
        }
        return current
    }

    public func tick(now: Double) async -> FanControlStatus {
        guard !busy else { return current }
        busy = true
        defer { finishOperation() }
        if current.phase == .needsRecovery || recoveryRequested { return await recover(reason: current.message) }
        guard current.phase == .applied, let preset = current.preset else { return current }
        let entryNow = try? operationTime(startedAt: now)
        guard let entryNow, let heartbeat = lastHeartbeat, entryNow >= heartbeat, entryNow - heartbeat <= leaseDuration,
              let previousTick = lastTick, entryNow >= previousTick else { return await recover(reason: "控制租约超时或时钟回退") }
        do {
            let capabilities = try await checkedCapabilities()
            guard Set(capabilities.map(\.index)) == Set(current.targets.keys) else { throw FanControlError.invalid("风扇能力集合发生变化") }
            let snapshot = try await device.snapshot(sensorKey: requestedSensorKey(for: preset.configuration))
            try confirm(snapshot, targets: current.targets)
            let sampledNow = try operationTime(startedAt: now)
            try checkLease(now: sampledNow)
            let targets = try makeTargets(preset.configuration, capabilities: capabilities, snapshot: snapshot, now: sampledNow, ramp: true)
            // 同一时刻或目标没有变化时不重复写SMC，仍执行租约与设备回读检查。
            if targets != current.targets { try await writeAndConfirm(targets) }
            if recoveryRequested { return await recover(reason: "已请求恢复系统控制") }
            let confirmedNow = try operationTime(startedAt: now)
            try checkLease(now: confirmedNow)
            lastTick = confirmedNow
            current = FanControlStatus(phase: .applied, preset: preset, targets: targets)
        } catch { return await recover(reason: String(describing: error)) }
        return current
    }

    public func restoreSystem() async -> FanControlStatus {
        // actor在await期间可重入；恢复请求不会被正在进行的写操作覆盖。
        recoveryRequested = true
        if busy {
            // 必须等待硬件写入及其恢复回读结束；调用者可据返回值判断shutdown是否真正安全。
            return await withCheckedContinuation { recoveryWaiters.append($0) }
        }
        busy = true
        defer { finishOperation() }
        return await recover(reason: nil)
    }
    public func shutdown() async -> FanControlStatus { await restoreSystem() }

    private func finishOperation() {
        busy = false
        let waiters = recoveryWaiters
        recoveryWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: current) }
    }
    private func operationTime(startedAt: Double) throws -> Double {
        // now是本轮调用起点；SMC异步采样在它之后发生，验证必须使用await结束后的同一单调时钟。
        let completedAt = clock()
        guard startedAt.isFinite, completedAt.isFinite else { throw FanControlError.invalid("控制单调时钟无效或回退") }
        return max(startedAt, completedAt)
    }
    private func checkLease(now: Double) throws {
        guard let lastHeartbeat, now >= lastHeartbeat, now - lastHeartbeat <= leaseDuration else { throw FanControlError.invalid("设备操作期间控制租约已超时") }
    }
    private func checkedCapabilities() async throws -> [FanCapability] {
        let capabilities = try await device.capabilities()
        guard !capabilities.isEmpty, Set(capabilities.map(\.index)).count == capabilities.count,
              capabilities.allSatisfy({ $0.index >= 0 && $0.minimumRPM.isFinite && $0.maximumRPM.isFinite && $0.minimumRPM >= 0 && $0.maximumRPM > $0.minimumRPM }) else {
            throw FanControlError.invalid("设备没有有效的可控制风扇")
        }
        guard owned.isSubset(of: Set(capabilities.map(\.index))) else { throw FanControlError.invalid("已接管风扇不在当前能力集合中") }
        return capabilities
    }
    private func requestedSensorKey(for configuration: FanControlConfiguration) throws -> String? {
        // 定向读取前校验组合；写后确认和恢复仍用普通快照，不依赖温度可用性。
        guard case .thermal(let rule) = configuration else { return nil }
        guard rule.hasValidSensorSelection else { throw FanControlError.invalid("温控传感器选择无效") }
        return rule.sensorKey
    }
    private func makeTargets(_ configuration: FanControlConfiguration, capabilities: [FanCapability], snapshot: FanDeviceSnapshot, now: Double, ramp: Bool) throws -> [Int: Double] {
        var desired: Double = 0
        var thermalFraction: Double?
        var thermalRule: FanThermalRule?
        var rampRate: Double?
        switch configuration {
        case .fixed(let rpm):
            guard rpm.isFinite, capabilities.allSatisfy({ ($0.minimumRPM...$0.maximumRPM).contains(rpm) }) else { throw FanControlError.invalid("目标转速超出设备范围") }
            desired = rpm
        case .fixedTargets(let targets):
            guard targets.count == capabilities.count, Set(targets.map(\.index)) == Set(capabilities.map(\.index)),
                  Set(targets.map(\.index)).count == targets.count else { throw FanControlError.invalid("独立目标必须覆盖全部风扇且不能重复") }
            for fan in capabilities {
                guard let target = targets.first(where: { $0.index == fan.index }), target.rpm.isFinite,
                      (fan.minimumRPM...fan.maximumRPM).contains(target.rpm) else { throw FanControlError.invalid("独立目标转速超出设备范围") }
            }
            return Dictionary(uniqueKeysWithValues: targets.map { ($0.index, $0.rpm.rounded()) })
        case .thermal(let rule):
            guard [rule.lowerTemperature, rule.upperTemperature].allSatisfy(\.isFinite),
                  rule.lowerTemperature >= 0, rule.upperTemperature <= 150, rule.upperTemperature > rule.lowerTemperature,
                  rule.lowerRPM.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  rule.upperRPM.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  capabilities.allSatisfy({ (rule.lowerRPM ?? $0.minimumRPM) <= (rule.upperRPM ?? $0.maximumRPM) }),
                  rule.rampRPMPerSecond.map({ $0.isFinite && $0 > 0 }) ?? true else { throw FanControlError.invalid("两点温控参数无效") }
            guard snapshot.sampledAt.isFinite, now >= snapshot.sampledAt, now - snapshot.sampledAt <= sensorMaximumAge else { throw FanControlError.invalid("温度采样已过期") }
            let temperature: Double?
            switch rule.sensor {
            case .cpu: temperature = snapshot.cpuTemperature
            case .gpu: temperature = snapshot.gpuTemperature
            case .sensor:
                // 精确匹配用户选择的键；缺失或失效时由下方检查触发恢复，禁止回退到CPU/GPU。
                temperature = rule.sensorKey.flatMap { snapshot.sensorTemperatures[$0] }
            case .maxCPUAndGPU:
                // 最大值策略依赖两个传感器，任何一项缺失均不能悄悄改为另一项。
                if let cpu = snapshot.cpuTemperature, let gpu = snapshot.gpuTemperature,
                   cpu.isFinite, gpu.isFinite, cpu > 0, gpu > 0, cpu <= 150, gpu <= 150 {
                    temperature = max(cpu, gpu)
                } else { temperature = nil }
            }
            guard let temperature, temperature.isFinite, temperature > 0, temperature <= 150 else { throw FanControlError.invalid("温控传感器不可用") }
            let fraction = min(1, max(0, (temperature - rule.lowerTemperature) / (rule.upperTemperature - rule.lowerTemperature)))
            thermalFraction = fraction; thermalRule = rule
            rampRate = rule.rampRPMPerSecond
        }
        return Dictionary(uniqueKeysWithValues: capabilities.map { fan in
            // 未指定RPM端点时逐风扇使用自己的硬件范围，不能共用另一只风扇的上限。
            let low = thermalRule?.lowerRPM ?? fan.minimumRPM
            let high = thermalRule?.upperRPM ?? fan.maximumRPM
            let target = thermalFraction.map { low + $0 * (high - low) } ?? desired
            var value = min(fan.maximumRPM, max(fan.minimumRPM, target))
            if ramp, let rate = rampRate, let previous = current.targets[fan.index], let lastTick {
                let change = rate * max(0, now - lastTick)
                value = min(previous + change, max(previous - change, value))
            }
            return (fan.index, value.rounded())
        })
    }
    private func writeAndConfirm(_ targets: [Int: Double]) async throws {
        for index in targets.keys.sorted() {
            // 必须在写前记为接管候选：写调用报错也可能已部分修改硬件。
            owned.insert(index)
            try await device.setManualRPM(index: index, rpm: targets[index]!)
        }
        try confirm(try await device.snapshot(), targets: targets)
    }
    private func confirm(_ snapshot: FanDeviceSnapshot, targets: [Int: Double]) throws {
        for (index, target) in targets {
            let entries = snapshot.fans.filter { $0.index == index }
            guard entries.count == 1, let state = entries.first, state.mode == .manual,
                  let readback = state.targetRPM, readback.isFinite, abs(readback - target) <= 1 else { throw FanControlError.invalid("风扇 \(index + 1) 未确认目标转速") }
        }
    }
    private func recover(reason: String?) async -> FanControlStatus {
        leaseID = nil; lastHeartbeat = nil; lastTick = nil
        var errors: [String] = []
        var restoredWithoutError: Set<Int> = []
        for index in owned.sorted() {
            do { try await device.restoreSystem(index: index); restoredWithoutError.insert(index) }
            catch { errors.append("风扇 \(index + 1)：\(error)") }
        }
        if !owned.isEmpty {
            do {
                let snapshot = try await device.snapshot()
                for index in owned {
                    let states = snapshot.fans.filter { $0.index == index }
                    // mode回到system仍可能有Ftst或恢复日志失败；设备恢复成功且回读确认才释放所有权。
                    if restoredWithoutError.contains(index), states.count == 1, states.first?.mode == .system { owned.remove(index) }
                }
            } catch { errors.append("恢复回读失败：\(error)") }
        }
        recoveryRequested = !owned.isEmpty
        if owned.isEmpty {
            let reportedReason = recoveryWaiters.isEmpty ? reason : nil
            current = FanControlStatus(phase: reportedReason == nil ? .system : .failed, message: reportedReason)
        } else {
            let message = ([reason].compactMap { $0 } + errors + ["系统控制尚未确认，等待重试"]).joined(separator: "；")
            current = FanControlStatus(phase: .needsRecovery, recoveryIndices: owned.sorted(), message: message)
        }
        return current
    }
}
