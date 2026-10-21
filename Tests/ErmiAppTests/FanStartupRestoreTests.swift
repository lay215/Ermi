import Foundation
import Testing
import ErmiCore
@testable import Ermi

@MainActor private final class RestoreConnection: FanControlConnection {
    var usesLocalMode = true
    var localSetupMessage = ""
    var ready = true
    var status = FanControlStatus(phase: .system)
    var applications: [FanPreset] = []
    var applyReply: FanServiceReply?
    var sensorSelectionSupport: Bool? = true
    var enables = 0
    var inspections = 0
    var blockedInspection: CheckedContinuation<Void, Never>?
    var blockInspection = false
    var blockApply = false
    var checkApplyCancellation = false
    var cancelledApply = false
    var blockedApply: CheckedContinuation<Void, Never>?
    func enable() { enables += 1 }
    func disconnect() {}
    func request(_ command: FanServiceCommand) async throws -> FanServiceReply {
        guard ready else { throw CocoaError(.fileReadNoPermission) }
        switch command {
        case .inspect:
            inspections += 1
            if blockInspection { await withCheckedContinuation { blockedInspection = $0 } }
        case .apply(let preset):
            applications.append(preset)
            if blockApply {
                await withCheckedContinuation { blockedApply = $0 }
                if checkApplyCancellation {
                    do { try Task.checkCancellation() }
                    catch { cancelledApply = true; throw error }
                }
                return .init(status: .init(phase: .applied, preset: preset))
            }
            if let applyReply { return applyReply }
            status = .init(phase: .applied, preset: preset)
        case .restore: status = .init(phase: .system)
        case .heartbeat: break
        }
        // 恢复测试模拟实际可控双风扇设备；空能力现在明确表示无风扇。
        return .init(capabilities: [
            .init(index: 0, name: "Fan 1", minimumRPM: 1000, maximumRPM: 6000),
            .init(index: 1, name: "Fan 2", minimumRPM: 1000, maximumRPM: 6000)
        ], status: status, supportsTemperatureSensorSelection: sensorSelectionSupport)
    }
}

@MainActor struct FanStartupRestoreTests {
    private let key = "ermi.lastAppliedFanPreset"
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
    private func model(_ connection: RestoreConnection, _ defaults: UserDefaults) -> MonitorModel {
        MonitorModel(fanClient: connection, defaults: defaults, loadLocalCapabilities: { [] }, loadLocalPresets: { [] })
    }
    @Test func builtinRulesKeepTheirOriginalDefaultsWithoutSavedSelection() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = model(RestoreConnection(), defaults)
        #expect(first.defaultFanTemperatureSource == .maxCPUAndGPU)
        #expect(first.defaultFanTemperatureSensorKey == nil)
        #expect(first.builtinFanPreset(named: "均衡").configuration == .thermal(.init(
            sensor: .maxCPUAndGPU, lowerTemperature: 50, upperTemperature: 80)))
        #expect(first.builtinFanPreset(named: "积极散热").configuration == .thermal(.init(
            sensor: .maxCPUAndGPU, lowerTemperature: 50, upperTemperature: 70)))
    }

    @Test(arguments: [false, true])
    func directSelectionUpdatesActiveBuiltinAndIsSharedByBothRules(legacy: Bool) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RestoreConnection()
        let first = model(connection, defaults)
        defer { first.stop() }
        await first.enableFanControl()
        let original = legacy ? FanPreset(name: "均衡", configuration: .thermal(.init(
            sensor: .maxCPUAndGPU, lowerTemperature: 50, upperTemperature: 80))) : first.builtinFanPreset(named: "均衡")
        if legacy {
            first.start()
            try await waitFor { first.isBuiltinFanPreset(original) && first.canApplyFanControl }
        }
        first.applyFanPreset(original)
        try await waitFor { !first.controlBusy }
        first.selectDefaultFanTemperatureSource(.cpu)
        try await waitFor { !first.controlBusy }
        #expect(first.defaultFanTemperatureSource == .cpu)
        #expect(first.fanStatus.preset?.configuration == .thermal(.init(sensor: .cpu, lowerTemperature: 50, upperTemperature: 80)))
        first.applyFanPreset(first.builtinFanPreset(named: "积极散热"))
        try await waitFor { !first.controlBusy }
        #expect(first.fanStatus.preset?.configuration == .thermal(.init(sensor: .cpu, lowerTemperature: 50, upperTemperature: 70)))
        first.selectDefaultFanTemperatureSource(.sensor, sensorKey: "Tp01")
        try await waitFor { !first.controlBusy }
        #expect(first.fanStatus.preset?.configuration == .thermal(.init(sensor: .sensor, lowerTemperature: 50, upperTemperature: 70, sensorKey: "Tp01")))
        #expect(first.builtinFanPreset(named: "均衡").configuration == .thermal(.init(sensor: .sensor, lowerTemperature: 50, upperTemperature: 80, sensorKey: "Tp01")))
        let nextLaunch = model(RestoreConnection(), defaults)
        #expect(nextLaunch.defaultFanTemperatureSource == .sensor)
        #expect(nextLaunch.defaultFanTemperatureSensorKey == "Tp01")
    }

    @Test(arguments: ["system", "fixed", "custom", "sameNameCustom"])
    func inactiveBuiltinSelectionOnlySavesPreference(mode: String) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RestoreConnection()
        let first = model(connection, defaults)
        defer { first.stop() }
        await first.enableFanControl()
        var original: FanPreset?
        if mode == "fixed" { original = .init(name: "固定", configuration: .fixed(rpm: 3000)) }
        else if mode == "custom" || mode == "sameNameCustom" {
            original = .init(name: mode == "sameNameCustom" ? "均衡" : "个人规则", configuration: .thermal(.init(
                sensor: mode == "sameNameCustom" ? .maxCPUAndGPU : .gpu, lowerTemperature: 50,
                upperTemperature: mode == "sameNameCustom" ? 80 : 75)))
            // 同名且参数恰好相同的已保存用户方案仍以 ID 判定，不能冒充内置方案。
            first.fanPresets = [original!]
        }
        if let original {
            first.applyFanPreset(original)
            try await waitFor { !first.controlBusy }
        }
        let applications = connection.applications
        let remembered = defaults.data(forKey: key)
        first.selectDefaultFanTemperatureSource(.sensor, sensorKey: "Tp01")
        #expect(connection.applications == applications)
        #expect(first.fanStatus.preset == original)
        #expect(defaults.data(forKey: key) == remembered)
        #expect(first.defaultFanTemperatureSource == .sensor)
        #expect(first.defaultFanTemperatureSensorKey == "Tp01")
        #expect(first.builtinFanPreset(named: "积极散热").configuration == .thermal(.init(
            sensor: .sensor, lowerTemperature: 50, upperTemperature: 70, sensorKey: "Tp01")))
        if mode == "custom" || mode == "sameNameCustom" {
            first.selectFanMode(.fixed)
            try await waitFor { !first.controlBusy }
            first.selectFanMode(.auto)
            try await waitFor { !first.controlBusy }
            #expect(first.fanStatus.preset == original)
        }
    }

    @Test(arguments: [false, true])
    func returningToAutoUsesBalancedWhenCustomRuleWasDeletedOrChangedToFixed(changedToFixed: Bool) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RestoreConnection()
        let first = model(connection, defaults)
        defer { first.stop() }
        await first.enableFanControl()
        let original = FanPreset(name: "均衡", configuration: .thermal(.init(
            sensor: .maxCPUAndGPU, lowerTemperature: 50, upperTemperature: 80)))
        first.fanPresets = [original]
        first.applyFanPreset(original)
        try await waitFor { !first.controlBusy }
        first.fanPresets = changedToFixed ? [FanPreset(id: original.id, name: original.name, configuration: .fixed(rpm: 3500))] : []
        first.selectFanMode(.fixed)
        try await waitFor { !first.controlBusy }
        first.selectFanMode(.auto)
        try await waitFor { !first.controlBusy }
        #expect(first.fanMode == .auto)
        #expect(first.fanStatus.preset == first.builtinFanPreset(named: "均衡"))
    }

    @Test(arguments: ["error", "mismatch", "failed", "oldHelper"])
    func failedActiveBuiltinSelectionDoesNotPolluteSavedPreference(kind: String) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RestoreConnection()
        if kind == "oldHelper" { connection.sensorSelectionSupport = nil }
        let first = model(connection, defaults)
        defer { first.stop() }
        await first.enableFanControl()
        first.applyFanPreset(first.builtinFanPreset(named: "均衡"))
        try await waitFor { !first.controlBusy }
        let remembered = defaults.data(forKey: key)
        if kind != "oldHelper" {
            connection.applyReply = .init(status: .init(phase: kind == "failed" ? .failed : .applied,
                preset: kind == "mismatch" ? .init(name: "其他", configuration: .thermal(.init(
                    sensor: .gpu, lowerTemperature: 55, upperTemperature: 85))) : first.fanStatus.preset),
                error: kind == "error" ? "被拒绝" : nil)
        }
        first.selectDefaultFanTemperatureSource(.sensor, sensorKey: "Tp01")
        try await waitFor { !first.controlBusy }
        #expect(connection.applications.count == (kind == "oldHelper" ? 1 : 2))
        #expect(first.defaultFanTemperatureSource == .maxCPUAndGPU)
        #expect(first.defaultFanTemperatureSensorKey == nil)
        #expect(defaults.data(forKey: key) == remembered)
        let nextLaunch = model(RestoreConnection(), defaults)
        #expect(nextLaunch.defaultFanTemperatureSource == .maxCPUAndGPU)
        #expect(nextLaunch.defaultFanTemperatureSensorKey == nil)
        if kind == "oldHelper" { #expect(first.controlNotice.contains("安装 / 更新授权")) }
    }

    @Test func pendingBuiltinSelectionWaitsForDeviceConfirmationBeforeSaving() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RestoreConnection()
        let first = model(connection, defaults)
        defer { first.stop() }
        await first.enableFanControl()
        first.applyFanPreset(first.builtinFanPreset(named: "均衡"))
        try await waitFor { !first.controlBusy }
        connection.blockApply = true
        first.selectDefaultFanTemperatureSource(.gpu)
        try await waitFor { connection.blockedApply != nil }
        #expect(first.defaultFanTemperatureSource == .maxCPUAndGPU)
        #expect(model(RestoreConnection(), defaults).defaultFanTemperatureSource == .maxCPUAndGPU)
        connection.blockedApply?.resume()
        connection.blockedApply = nil
        try await waitFor { !first.controlBusy }
        #expect(first.defaultFanTemperatureSource == .gpu)
        #expect(model(RestoreConnection(), defaults).defaultFanTemperatureSource == .gpu)
    }

    @Test func selectedBuiltinSourceSurvivesStartupAndModeReturns() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = model(RestoreConnection(), defaults)
        await first.enableFanControl()
        first.selectDefaultFanTemperatureSource(.sensor, sensorKey: "Tp01")
        first.applyFanPreset(first.builtinFanPreset(named: "积极散热"))
        try await waitFor { !first.controlBusy }
        let original = first.fanStatus.preset
        first.stop()
        let connection = RestoreConnection()
        let second = model(connection, defaults)
        defer { second.stop() }
        second.start()
        try await waitFor { !connection.applications.isEmpty && !second.controlBusy }
        #expect(second.fanStatus.preset == original)
        #expect(second.defaultFanTemperatureSensorKey == "Tp01")
        for mode in [FanMode.fixed, .system] {
            second.selectFanMode(mode)
            try await waitFor { !second.controlBusy }
            if mode == .system { #expect(defaults.data(forKey: key) == nil) }
            second.selectFanMode(.auto)
            try await waitFor { !second.controlBusy }
            #expect(second.fanStatus.preset == original)
        }
    }

    @Test func failedSensorCanBeReplacedWhileSystemControlsFans() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RestoreConnection()
        let first = model(connection, defaults)
        defer { first.stop() }
        await first.enableFanControl()
        first.selectDefaultFanTemperatureSource(.sensor, sensorKey: "Tp01")
        first.selectFanMode(.auto)
        try await waitFor { !first.controlBusy }
        // helper 温度失效后恢复系统控制；修正来源本身不重新接管，用户再次选自动才提交。
        connection.status = .init(phase: .failed, message: "传感器不可用")
        await first.enableFanControl()
        #expect(first.fanMode == .system)
        first.selectDefaultFanTemperatureSource(.maxCPUAndGPU)
        #expect(connection.applications.count == 1)
        first.selectFanMode(.auto)
        try await waitFor { !first.controlBusy }
        #expect(first.fanStatus.preset?.configuration == .thermal(.init(
            sensor: .maxCPUAndGPU, lowerTemperature: 50, upperTemperature: 80)))
        #expect(connection.applications.count == 2)
    }

    @Test func inspectingOtherControllerDoesNotOverwriteLocalBuiltinPreference() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RestoreConnection()
        let first = model(connection, defaults)
        defer { first.stop() }
        first.selectDefaultFanTemperatureSource(.cpu)
        var external = first.builtinFanPreset(named: "均衡")
        external.configuration = .thermal(.init(sensor: .gpu, lowerTemperature: 50, upperTemperature: 80))
        connection.status = .init(phase: .applied, preset: external)
        await first.enableFanControl()
        #expect(first.defaultFanTemperatureSource == .gpu)
        #expect(connection.applications.isEmpty)
        let nextLaunch = model(RestoreConnection(), defaults)
        #expect(nextLaunch.defaultFanTemperatureSource == .cpu)
        #expect(defaults.data(forKey: key) == nil)
        first.applyFanPreset(first.builtinFanPreset(named: "积极散热"))
        try await waitFor { !first.controlBusy }
        #expect(first.fanStatus.preset?.configuration == .thermal(.init(sensor: .gpu, lowerTemperature: 50, upperTemperature: 70)))
        #expect(model(RestoreConnection(), defaults).defaultFanTemperatureSource == .gpu)
    }

    @Test func delayedLocalPresetLoadDoesNotMisidentifyRestoredCustomRuleAsBuiltin() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferenceWriter = model(RestoreConnection(), defaults)
        preferenceWriter.selectDefaultFanTemperatureSource(.gpu)
        let custom = FanPreset(name: "均衡", configuration: .thermal(.init(
            sensor: .maxCPUAndGPU, lowerTemperature: 50, upperTemperature: 80)))
        defaults.set(try JSONEncoder().encode(custom), forKey: key)
        let gate = StartupLoadGate()
        defer { gate.release(); #expect(!gate.timedOut) }
        let connection = RestoreConnection()
        let first = MonitorModel(fanClient: connection, defaults: defaults, loadLocalCapabilities: {
            gate.wait()
            return []
        }, loadLocalPresets: {
            gate.wait()
            return [custom]
        })
        defer { first.stop() }
        first.start()
        try await waitFor { connection.applications == [custom] && !first.controlBusy }
        #expect(first.fanPresets.isEmpty)
        #expect(!first.isBuiltinFanPreset(custom))
        #expect(first.defaultFanTemperatureSource == .gpu)
        #expect(model(RestoreConnection(), defaults).defaultFanTemperatureSource == .gpu)
        gate.release()
        try await waitFor { first.fanPresets == [custom] }
        #expect(!first.isBuiltinFanPreset(custom))
        #expect(first.fanStatus.preset == custom)
        #expect(first.defaultFanTemperatureSource == .gpu)
    }
    @Test(arguments: [
        FanControlConfiguration.fixed(rpm: 3200),
        .fixedTargets([.init(index: 0, rpm: 3100), .init(index: 1, rpm: 3500)]),
        .thermal(.init(sensor: .maxCPUAndGPU, lowerTemperature: 50, upperTemperature: 80, lowerRPM: 2000, upperRPM: 5000, rampRPMPerSecond: 250))
    ])
    func confirmedConfigurationSurvivesNewModel(configuration: FanControlConfiguration) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preset = FanPreset(name: "完整配置", configuration: configuration)
        let first = model(RestoreConnection(), defaults)
        first.helperReady = true
        first.applyFanPreset(preset)
        try await waitFor { !first.controlBusy }
        first.stop()
        let connection = RestoreConnection()
        let second = model(connection, defaults)
        defer { second.stop() }
        second.start()
        try await waitFor { !connection.applications.isEmpty }
        #expect(connection.applications == [preset])
    }

    @Test(arguments: ["system", "exit", "sleep"])
    func explicitSystemClearsButLifecycleRestorePreserves(action: String) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preset = FanPreset(name: "保存", configuration: .fixed(rpm: 3200))
        let first = model(RestoreConnection(), defaults)
        first.helperReady = true
        first.applyFanPreset(preset)
        try await waitFor { !first.controlBusy }
        if action == "system" {
            first.selectFanMode(.system)
            try await waitFor { !first.controlBusy }
        } else if action == "exit" { _ = await first.prepareForExit() }
        else { await first.prepareForSleep() }
        first.stop()
        #expect((defaults.data(forKey: key) == nil) == (action == "system"))
    }

    @Test(arguments: ["error", "mismatch", "failed"])
    func unconfirmedApplyNeverPersists(kind: String) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preset = FanPreset(name: "保存", configuration: .fixed(rpm: 3200))
        let connection = RestoreConnection()
        connection.applyReply = .init(status: .init(phase: kind == "failed" ? .failed : .applied,
            preset: kind == "mismatch" ? FanPreset(name: "其他", configuration: .fixed(rpm: 3300)) : preset),
            error: kind == "error" ? "被拒绝" : nil)
        let first = model(connection, defaults)
        defer { first.stop() }
        first.helperReady = true
        first.applyFanPreset(preset)
        try await waitFor { !first.controlBusy }
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test func failedStartupIsNotRetriedAndNoticeSurvivesHeartbeat() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(FanPreset(name: "保存", configuration: .fixed(rpm: 3200))), forKey: key)
        let connection = RestoreConnection()
        connection.applyReply = .init(error: "恢复配置失败")
        let first = model(connection, defaults)
        defer { first.stop() }
        first.start()
        try await waitFor { connection.applications.count == 1 && !first.controlBusy }
        try await Task.sleep(for: .milliseconds(2200))
        #expect(connection.applications.count == 1)
        #expect(first.controlNotice == "恢复配置失败")
        #expect(first.controlNeedsAttention)
    }

    @Test(arguments: ["user", "sleep", "stop", "exit", "authorization"])
    func newIntentCancelsPendingStartup(action: String) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(FanPreset(name: "旧", configuration: .fixed(rpm: 3200))), forKey: key)
        let connection = RestoreConnection()
        connection.blockInspection = true
        let first = model(connection, defaults)
        defer { first.stop() }
        first.start()
        try await waitFor { connection.blockedInspection != nil }
        if action == "user" {
            first.helperReady = true
            first.applyFanPreset(FanPreset(name: "新", configuration: .fixed(rpm: 3400)))
            try await waitFor { !first.controlBusy }
        } else if action == "sleep" { await first.prepareForSleep() }
        else if action == "stop" { first.stop() }
        else if action == "exit" { _ = await first.prepareForExit() }
        else {
            // 未授权的显式入口应只连接，不能在授权结束后重放保存配置。
            connection.blockInspection = false
            await first.enableFanControl()
        }
        connection.blockedInspection?.resume()
        connection.blockedInspection = nil
        for _ in 0..<30 { await Task.yield() }
        #expect(connection.applications.map(\.name) == (action == "user" ? ["新"] : []))
    }

    @Test func explicitSystemAfterInFlightStartupStillRestoresHardware() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(FanPreset(name: "旧", configuration: .fixed(rpm: 3200))), forKey: key)
        let connection = RestoreConnection()
        connection.blockApply = true
        let first = model(connection, defaults)
        defer { first.stop() }
        first.start()
        try await waitFor { connection.blockedApply != nil }
        first.selectFanMode(.system)
        connection.blockedApply?.resume()
        connection.blockedApply = nil
        try await waitFor { !first.controlBusy }
        #expect(first.fanStatus.phase == .system)
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test(arguments: [false, true]) func exitDiscardsInFlightAutomaticApplyReply(checkCancellation: Bool) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(FanPreset(name: "旧", configuration: .fixed(rpm: 3200))), forKey: key)
        let connection = RestoreConnection()
        connection.blockApply = true
        connection.checkApplyCancellation = checkCancellation
        let first = model(connection, defaults)
        defer { first.stop() }
        first.start()
        try await waitFor { connection.blockedApply != nil }
        // 退出也要丢弃自动恢复期间排队的新选择，不能由迟到任务的 defer 重新发出。
        first.selectFanMode(.auto)
        #expect(await first.prepareForExit())
        connection.blockApply = false
        connection.blockedApply?.resume()
        connection.blockedApply = nil
        try await waitFor { !first.controlBusy }
        #expect(first.fanStatus.phase == .system)
        #expect(connection.cancelledApply == checkCancellation)
        #expect(connection.applications.count == 1)
    }

    @Test func connectionFailureCanRecoverOnceWithoutOpeningAuthorization() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preset = FanPreset(name: "保存", configuration: .fixed(rpm: 3200))
        defaults.set(try JSONEncoder().encode(preset), forKey: key)
        let connection = RestoreConnection()
        connection.ready = false
        let first = model(connection, defaults)
        defer { first.stop() }
        first.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(connection.applications.isEmpty)
        #expect(connection.enables == 0)
        connection.ready = true
        try await waitFor { connection.applications.count == 1 && !first.controlBusy }
        #expect(connection.applications == [preset])
        #expect(connection.enables == 0)
        await first.prepareForSleep()
        first.resumeAfterSleep()
        try await waitFor { connection.applications.count == 2 && !first.controlBusy }
        #expect(connection.applications == [preset, preset])
        #expect(first.fanStatus.phase == .applied)
    }

    @Test(arguments: ["missing", "corrupt", "unauthorized", "applied", "needsRecovery"])
    func noUnexpectedTakeover(state: String) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preset = FanPreset(name: "旧", configuration: .fixed(rpm: 3200))
        if state != "missing" { defaults.set(state == "corrupt" ? Data([0]) : try JSONEncoder().encode(preset), forKey: key) }
        let connection = RestoreConnection()
        connection.ready = state != "unauthorized"
        if state == "applied" { connection.status = .init(phase: .applied, preset: preset) }
        if state == "needsRecovery" { connection.status = .init(phase: .needsRecovery) }
        let first = model(connection, defaults)
        defer { first.stop() }
        first.start()
        try await Task.sleep(for: .milliseconds(100))
        connection.status = .init(phase: .system)
        try await Task.sleep(for: .milliseconds(2100))
        #expect(connection.applications.isEmpty)
        #expect(connection.enables == 0)
    }

    @Test(arguments: [FanControlConfiguration.fixed(rpm: 3200),
                      .fixedTargets([.init(index: 0, rpm: 3100), .init(index: 1, rpm: 3500)]),
                      .thermal(.init(sensor: .maxCPUAndGPU, lowerTemperature: 50, upperTemperature: 70))])
    func eachWakeRestoresConfirmedConfigurationOnce(configuration: FanControlConfiguration) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RestoreConnection()
        let first = model(connection, defaults)
        defer { first.stop() }
        first.helperReady = true
        let preset = FanPreset(name: "睡前模式", configuration: configuration)
        first.applyFanPreset(preset)
        try await waitFor { !first.controlBusy }
        for expectedCount in 2...3 {
            await first.prepareForSleep()
            #expect(first.fanStatus.phase == .system)
            first.resumeAfterSleep()
            first.resumeAfterSleep() // 重复通知不是新睡眠周期，不得重复应用。
            try await waitFor { connection.applications.count == expectedCount && !first.controlBusy }
            #expect(first.fanStatus.preset == preset)
        }
        #expect(connection.applications == [preset, preset, preset])
        first.selectFanMode(.system)
        try await waitFor { !first.controlBusy }
        await first.prepareForSleep()
        first.resumeAfterSleep()
        try await waitFor { first.helperReady }
        #expect(first.fanStatus.phase == .system)
        #expect(connection.applications.count == 3)
    }

    @Test func explicitSystemWhileWakeIsConnectingCancelsRememberedApply() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RestoreConnection()
        let first = model(connection, defaults)
        defer { first.stop() }
        first.helperReady = true
        first.applyFanPreset(.init(name: "睡前模式", configuration: .fixed(rpm: 3200)))
        try await waitFor { !first.controlBusy }
        await first.prepareForSleep()
        connection.blockInspection = true
        first.resumeAfterSleep()
        try await waitFor { connection.blockedInspection != nil }
        // 模拟用户的新系统模式选择已具备连接条件；迟到的唤醒 inspect 不得恢复旧配置。
        first.helperReady = true
        first.selectFanMode(.system)
        try await waitFor { !first.controlBusy }
        connection.blockInspection = false
        connection.blockedInspection?.resume()
        connection.blockedInspection = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(connection.applications.count == 1)
        #expect(first.fanStatus.phase == .system)
        #expect(defaults.data(forKey: key) == nil)
    }
}
