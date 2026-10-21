import Foundation
import Testing

@testable import ErmiCore

private final class FanTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
private enum FakeFanError: Error { case write, restore }
private actor FakeFanDevice: FanDevice {
    let limits = [FanCapability(index: 0, name: "A", minimumRPM: 1000, maximumRPM: 5000), FanCapability(index: 1, name: "B", minimumRPM: 1500, maximumRPM: 6000)]
    var states = [FanDeviceState(index: 0, mode: .system, targetRPM: nil, actualRPM: 2100), FanDeviceState(index: 1, mode: .system, targetRPM: nil, actualRPM: 2200)]
    var temperature: Double? = 65
    var sampledAt: Double = 100
    var sensorTemperatures: [String: Double] = [:]
    var requestedSensorKeys: [String?] = []
    var ordinarySnapshots = 0
    func sampleSensors(_ temperatures: [String: Double], at: Double) {
        sensorTemperatures = temperatures; sampledAt = at
    }
    var failWrite: Int?
    var failRestore: Int?
    var ignoreWrite = false
    var failAfterSystemWrite = false
    func failRestoreAfterSystemWrite(_ enabled: Bool) { failAfterSystemWrite = enabled }
    var writeCount = 0
    var paused = false
    var writeWaiter: CheckedContinuation<Void, Never>?
    var completionClock: FanTestClock?
    func pauseWrites() { paused = true }
    func resumeWrites() { paused = false; writeWaiter?.resume(); writeWaiter = nil }
    func updateClockOnWrite(_ clock: FanTestClock) { completionClock = clock }
    var restores: [Int] = []
    func externallyControlSecondFan() {
        states[1] = FanDeviceState(index: 1, mode: .manual, targetRPM: 2500, actualRPM: 2500)
    }
    func capabilities() -> [FanCapability] { limits }
    func snapshot() -> FanDeviceSnapshot {
        ordinarySnapshots += 1
        return FanDeviceSnapshot(fans: states, cpuTemperature: temperature, gpuTemperature: temperature, sampledAt: sampledAt)
    }
    func snapshot(sensorKey: String?) -> FanDeviceSnapshot {
        requestedSensorKeys.append(sensorKey)
        // 普通采样不提供具体键；定向快照保留其他温度，验证控制器不会误取另一传感器。
        let selected = sensorKey == nil ? [:] : sensorTemperatures
        return FanDeviceSnapshot(fans: states, cpuTemperature: temperature, gpuTemperature: temperature,
                                 sampledAt: sampledAt, sensorTemperatures: selected)
    }
    func setManualRPM(index: Int, rpm: Double) async throws {
        if paused { await withCheckedContinuation { writeWaiter = $0 } }
        completionClock?.set(120)
        writeCount += 1
        // 模拟抛错前已改变模式的半失败，确保控制器把当前风扇也列入回滚。
        if !ignoreWrite { states[index] = FanDeviceState(index: index, mode: .manual, targetRPM: rpm, actualRPM: 2200) }
        if failWrite == index { throw FakeFanError.write }
    }
    func restoreSystem(index: Int) throws {
        restores.append(index)
        if failRestore == index { throw FakeFanError.restore }
        states[index] = FanDeviceState(index: index, mode: .system, targetRPM: nil, actualRPM: 2200)
        if failAfterSystemWrite { throw FakeFanError.restore }
    }
    func failures(write: Int? = nil, restore: Int? = nil, ignore: Bool = false) { failWrite = write; failRestore = restore; ignoreWrite = ignore }
    func sample(_ temperature: Double?, at: Double) { self.temperature = temperature; sampledAt = at }
}

struct FanControlTests {
    private let fixed = FanPreset(name: "固定", configuration: .fixed(rpm: 3000))
    private func thermal(ramp: Double? = nil) -> FanPreset {
        FanPreset(name: "两点", configuration: .thermal(FanThermalRule(sensor: .cpu, lowerTemperature: 50, upperTemperature: 80, rampRPMPerSecond: ramp)))
    }
    private func sensorPreset(key: String? = "TC0P") -> FanPreset {
        FanPreset(name: "指定传感器", configuration: .thermal(FanThermalRule(
            sensor: .sensor, lowerTemperature: 50, upperTemperature: 80, sensorKey: key)))
    }
    @Test func selectedSensorDrivesApplyAndTickIndependentlyOfCPUAndGPU() async {
        let fake = FakeFanDevice()
        await fake.sampleSensors(["TC0P": 50, "TG0P": 80], at: 100)
        let controller = FanController(device: fake, clock: { 100 })
        let applied = await controller.apply(sensorPreset(), leaseID: UUID(), now: 100)
        #expect(applied.phase == .applied)
        #expect(applied.targets == [0: 1000, 1: 1500])
        await fake.sampleSensors(["TC0P": 80, "TG0P": 50], at: 101)
        #expect(await controller.tick(now: 101).targets == [0: 5000, 1: 6000])
        #expect(await fake.requestedSensorKeys == ["TC0P", "TC0P"])
        #expect(await controller.restoreSystem().phase == .system)
        #expect(await fake.ordinarySnapshots == 3)
    }
    @Test func invalidSensorKeysAndSourceCombinationsNeverWrite() async {
        let invalidKeys: [String?] = [nil, "", "TC0", "TC0PX", "XC0P", "tc0p", "Té0", "T_0P", "T 0P", "T\u{0000}0P"]
        var presets = invalidKeys.map { sensorPreset(key: $0) }
        for source in [FanTemperatureSource.cpu, .gpu, .maxCPUAndGPU] {
            presets.append(FanPreset(name: "非法组合", configuration: .thermal(FanThermalRule(
                sensor: source, lowerTemperature: 50, upperTemperature: 80, sensorKey: "TC0P"))))
        }
        for preset in presets {
            let fake = FakeFanDevice()
            if case .thermal(let rule) = preset.configuration, let key = rule.sensorKey {
                await fake.sampleSensors([key: 65], at: 100)
            }
            let controller = FanController(device: fake, clock: { 100 })
            #expect(await controller.apply(preset, leaseID: UUID(), now: 100).phase == .failed)
            #expect(await fake.writeCount == 0)
            #expect(await fake.restores.isEmpty)
        }
    }
    @Test func storeRejectsInvalidSensorSelectionsAndPreservesExistingPresets() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FanPresetStore(url: folder.appendingPathComponent("presets.json"))
        try await store.save([fixed])
        let invalidKeys: [String?] = [nil, "", "TC0", "TC0PX", "XC0P", "tc0p", "Té0", "T_0P", "T 0P", "T\u{0000}0P"]
        var invalid = invalidKeys.map { sensorPreset(key: $0) }
        for source in [FanTemperatureSource.cpu, .gpu, .maxCPUAndGPU] {
            invalid.append(FanPreset(name: "非法组合", configuration: .thermal(FanThermalRule(
                sensor: source, lowerTemperature: 50, upperTemperature: 80, sensorKey: "TC0P"))))
        }
        for preset in invalid {
            await #expect(throws: FanPresetStoreError.self) { try await store.save([preset]) }
            #expect(try await store.load() == [fixed])
        }
    }
    @Test func storeRejectsInvalidSensorSelectionsWhenLoading() async throws {
        struct Document: Encodable { let version = 1; let presets: [FanPreset] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("presets.json")
        let invalid = [sensorPreset(key: nil), sensorPreset(key: "T_0P"), FanPreset(
            name: "旧来源夹带键", configuration: .thermal(FanThermalRule(
                sensor: .cpu, lowerTemperature: 50, upperTemperature: 80, sensorKey: "TC0P")))]
        let store = FanPresetStore(url: url)
        for preset in invalid {
            let data = try JSONEncoder().encode(Document(presets: [preset]))
            try data.write(to: url)
            await #expect(throws: FanPresetStoreError.self) { try await store.load() }
            await #expect(throws: FanPresetStoreError.self) { try await store.save([fixed]) }
            #expect(try Data(contentsOf: url) == data)
        }
    }
    @Test func selectedSensorFailureRestoresWithoutFallingBackToOtherTemperatures() async {
        let invalidReadings: [Double?] = [nil, .nan, .infinity, -.infinity, 0, -1, 150.1]
        for reading in invalidReadings {
            let fake = FakeFanDevice()
            await fake.sampleSensors(["TC0P": 65], at: 100)
            let controller = FanController(device: fake, clock: { 100 })
            #expect(await controller.apply(sensorPreset(), leaseID: UUID(), now: 100).phase == .applied)
            var readings = ["TG0P": 80.0]
            readings["TC0P"] = reading
            await fake.sampleSensors(readings, at: 101)
            #expect(await controller.tick(now: 101).phase == .failed)
            #expect(await fake.writeCount == 2)
            #expect(await fake.restores == [0, 1])
            #expect(await fake.states.allSatisfy { $0.mode == .system })
        }
    }
    @Test func selectedSensorRejectsStaleFutureAndNonFiniteSamplingTimes() async {
        for sampledAt in [90.0, 102.0, .nan, .infinity] {
            let fake = FakeFanDevice()
            await fake.sampleSensors(["TC0P": 65], at: 100)
            let controller = FanController(device: fake, clock: { 100 })
            #expect(await controller.apply(sensorPreset(), leaseID: UUID(), now: 100).phase == .applied)
            await fake.sampleSensors(["TC0P": 80], at: sampledAt)
            #expect(await controller.tick(now: 101).phase == .failed)
            #expect(await fake.writeCount == 2)
            #expect(await fake.states.allSatisfy { $0.mode == .system })
        }
    }
    @Test func selectedSensorAcceptsAlphanumericKeyAndMaximumValidTemperature() async {
        let fake = FakeFanDevice()
        await fake.sampleSensors(["Ta9Z": 150], at: 100)
        let controller = FanController(device: fake, clock: { 100 })
        let applied = await controller.apply(sensorPreset(key: "Ta9Z"), leaseID: UUID(), now: 100)
        #expect(applied.phase == .applied)
        #expect(applied.targets == [0: 5000, 1: 6000])
    }
    @Test func legacyConfigurationsRequestNoSpecificSensor() async {
        for preset in [fixed, thermal()] {
            let fake = FakeFanDevice()
            let controller = FanController(device: fake, clock: { 100 })
            #expect(await controller.apply(preset, leaseID: UUID(), now: 100).phase == .applied)
            #expect(await controller.tick(now: 101).phase == .applied)
            #expect(await fake.requestedSensorKeys == [nil, nil])
        }
    }
    @Test func legacyPresetJSONWithoutSensorKeyRemainsReadable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("presets.json")
        let data = Data("""
        {"version":1,"presets":[{"id":"D9C20CA4-E3AF-4E6A-A184-650710D323F7","name":"旧温控",
        "configuration":{"thermal":{"_0":{"sensor":"cpu","lowerTemperature":50,"upperTemperature":80}}}}]}
        """.utf8)
        try data.write(to: url)
        let store = FanPresetStore(url: url)
        let presets = try await store.load()
        let preset = try #require(presets.first)
        guard case .thermal(let rule) = preset.configuration else { Issue.record("应保留旧温控策略"); return }
        #expect(rule.sensor == .cpu)
        #expect(rule.sensorKey == nil)
        #expect(rule.lowerTemperature == 50 && rule.upperTemperature == 80)
        try await store.save(presets)
        #expect(try await store.load() == presets)
    }
    @Test func specificSourceWireValueIsRejectedByLegacySourceDecoder() throws {
        enum LegacySource: String, Decodable { case cpu, gpu, maxCPUAndGPU }
        let encoded = try JSONEncoder().encode(FanTemperatureSource.sensor)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"sensor\"")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LegacySource.self, from: encoded) }
    }
    @Test func startupAndSavingDoNotTakeOwnership() async throws {
        let fake = FakeFanDevice()
        let controller = FanController(device: fake, clock: { 100 })
        #expect(await controller.status().phase == .system)
        #expect(await fake.writeCount == 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FanPresetStore(url: folder.appendingPathComponent("presets.json"))
        let presets = [fixed, thermal(), sensorPreset()]
        try await store.save(presets)
        #expect(try await store.load() == presets)
        #expect(await fake.writeCount == 0)
    }
    @Test func existingExternalControlIsRejectedBeforeAnyWriteOrRecovery() async {
        let fake = FakeFanDevice()
        await fake.externallyControlSecondFan()
        let controller = FanController(device: fake, clock: { 100 })
        let result = await controller.apply(fixed, leaseID: UUID(), now: 100)
        #expect(result.phase == .failed)
        #expect(result.recoveryIndices.isEmpty)
        #expect(await fake.writeCount == 0)
        #expect(await fake.restores.isEmpty)
        #expect(await fake.states[1].mode == .manual)
    }
    @Test func fixedReadbackConfirmedAndRestoreReturnsSystem() async {
        let fake = FakeFanDevice(), lease = UUID()
        let controller = FanController(device: fake, clock: { 100 })
        let applied = await controller.apply(fixed, leaseID: lease, now: 100)
        #expect(applied.phase == .applied)
        #expect(applied.targets == [0: 3000, 1: 3000])
        #expect(await fake.states.allSatisfy { $0.mode == .manual })
        #expect(await controller.restoreSystem().phase == .system)
        #expect(await fake.states.allSatisfy { $0.mode == .system })
    }
    @Test func ignoredWritesNeverBecomeApplied() async {
        let fake = FakeFanDevice(); await fake.failures(ignore: true)
        let controller = FanController(device: fake, clock: { 100 })
        #expect(await controller.apply(fixed, leaseID: UUID(), now: 100).phase == .failed)
        #expect(await fake.restores == [0, 1])
    }
    @Test func partialWriteRollsBackAllTouchedFansAndRetriesRecovery() async {
        let fake = FakeFanDevice(); await fake.failures(write: 1, restore: 0)
        let controller = FanController(device: fake, clock: { 100 })
        let failed = await controller.apply(fixed, leaseID: UUID(), now: 100)
        #expect(failed.phase == .needsRecovery)
        #expect(failed.recoveryIndices == [0])
        #expect(await fake.restores == [0, 1])
        await fake.failures()
        #expect(await controller.tick(now: 101).phase == .failed)
        #expect(await fake.states.allSatisfy { $0.mode == .system })
        #expect(await controller.restoreSystem().phase == .system)
    }
    @Test func expiredLeaseCannotBeRevivedAndRestoresFans() async {
        let fake = FakeFanDevice(), lease = UUID()
        let c = FanController(device: fake, clock: { 100 })
        _ = await c.apply(fixed, leaseID: lease, now: 100)
        #expect(await c.heartbeat(leaseID: UUID(), now: 105) == false)
        #expect(await c.heartbeat(leaseID: lease, now: 111) == false)
        #expect(await c.tick(now: 111).phase == .failed)
        #expect(await fake.states.allSatisfy { $0.mode == .system })
    }
    @Test func leaseHeartbeatAndRepeatedTicksAvoidDuplicateWrites() async {
        let fake = FakeFanDevice(), lease = UUID()
        let controller = FanController(device: fake, clock: { 100 })
        _ = await controller.apply(fixed, leaseID: lease, now: 100)
        #expect(await controller.heartbeat(leaseID: lease, now: 108))
        #expect(await controller.tick(now: 108).phase == .applied)
        #expect(await controller.tick(now: 108).phase == .applied)
        #expect(await fake.writeCount == 2)
    }
    @Test func thermalInterpolatesEachFansRangeAndRamps() async {
        let fake = FakeFanDevice(), lease = UUID()
        let c = FanController(device: fake, clock: { 100 })
        let initial = await c.apply(thermal(ramp: 100), leaseID: lease, now: 100)
        #expect(initial.targets == [0: 3000, 1: 3750])
        await fake.sample(80, at: 102)
        let ramped = await c.tick(now: 102)
        #expect(ramped.targets == [0: 3200, 1: 3950])
        #expect(await c.tick(now: 102).targets == ramped.targets)
        #expect(await fake.writeCount == 4)
    }
    @Test func unavailableAndStaleSensorsRestoreInsteadOfUsingOldTemperature() async {
        for missing in [false, true] {
            let fake = FakeFanDevice(), lease = UUID()
            let controller = FanController(device: fake, leaseDuration: 30, clock: { 100 })
            #expect(await controller.apply(thermal(), leaseID: lease, now: 100).phase == .applied)
            await fake.sample(missing ? nil : 70, at: 100)
            #expect(await controller.tick(now: missing ? 101 : 111).phase == .failed)
            #expect(await fake.states.allSatisfy { $0.mode == .system })
        }
    }
    @Test func invalidBoundsAndIncompleteIndependentTargetsDoNotWrite() async {
        let invalid: [FanControlConfiguration] = [.fixed(rpm: 999), .fixed(rpm: .nan), .fixedTargets([FanRPMTarget(index: 0, rpm: 3000)]), .fixedTargets([FanRPMTarget(index: 0, rpm: 3000), FanRPMTarget(index: 0, rpm: 3000)]), .thermal(FanThermalRule(sensor: .cpu, lowerTemperature: 80, upperTemperature: 50))]
        for configuration in invalid {
            let fake = FakeFanDevice()
            let controller = FanController(device: fake, clock: { 100 })
            #expect(await controller.apply(FanPreset(name: "无效", configuration: configuration), leaseID: UUID(), now: 100).phase == .failed)
            #expect(await fake.writeCount == 0)
        }
        let fake = FakeFanDevice()
        let c = FanController(device: fake, clock: { 100 })
        let result = await c.apply(FanPreset(name: "独立", configuration: .fixedTargets([FanRPMTarget(index: 0, rpm: 1000), FanRPMTarget(index: 1, rpm: 6000)])), leaseID: UUID(), now: 100)
        #expect(result.targets == [0: 1000, 1: 6000])
    }
    @Test func thermalEndpointsClampToEachFansBounds() async {
        for (temperature, expected) in [(40.0, [0: 1000.0, 1: 1500.0]), (95.0, [0: 5000.0, 1: 6000.0])] {
            let fake = FakeFanDevice()
            await fake.sample(temperature, at: 100)
            let controller = FanController(device: fake, clock: { 100 })
            #expect(await controller.apply(thermal(), leaseID: UUID(), now: 100).targets == expected)
        }
    }
    @Test func pendingRecoveryCannotBeReplacedByNewApply() async {
        let fake = FakeFanDevice()
        await fake.failures(write: 1, restore: 0)
        let controller = FanController(device: fake, clock: { 100 })
        _ = await controller.apply(fixed, leaseID: UUID(), now: 100)
        let count = await fake.writeCount
        #expect(await controller.apply(fixed, leaseID: UUID(), now: 101).phase == .needsRecovery)
        #expect(await fake.writeCount == count)
    }
    @Test func asynchronousSnapshotUsesCompletionClockInsteadOfRequestStart() async {
        let fake = FakeFanDevice(), clock = FanTestClock(101)
        await fake.sample(65, at: 101)
        let controller = FanController(device: fake, clock: { clock.read() })
        #expect(await controller.apply(thermal(), leaseID: UUID(), now: 100).phase == .applied)
        clock.set(102)
        await fake.sample(70, at: 102)
        #expect(await controller.tick(now: 101.5).phase == .applied)
        await fake.sample(70, at: 105)
        #expect(await controller.tick(now: 102).phase == .failed)
    }
    @Test func operationThatOutlivesLeaseRollsBackBeforeReportingApplied() async {
        let fake = FakeFanDevice(), clock = FanTestClock(100)
        await fake.updateClockOnWrite(clock)
        let controller = FanController(device: fake, clock: { clock.read() })
        #expect(await controller.apply(fixed, leaseID: UUID(), now: 100).phase == .failed)
        #expect(await fake.states.allSatisfy { $0.mode == .system })
    }
    @Test func shutdownDuringAwaitWaitsUntilReadbackConfirmsRestore() async {
        let fake = FakeFanDevice()
        await fake.pauseWrites()
        let controller = FanController(device: fake, clock: { 100 })
        let applying = Task { await controller.apply(fixed, leaseID: UUID(), now: 100) }
        while await fake.writeWaiter == nil { await Task.yield() }
        let shuttingDown = Task { await controller.shutdown() }
        // 让shutdown在暂停的设备调用期间进入actor，形成真实的重入恢复请求。
        for _ in 0..<20 { await Task.yield() }
        await fake.resumeWrites()
        _ = await applying.value
        #expect(await shuttingDown.value.phase == .system)
        #expect(await fake.states.allSatisfy { $0.mode == .system })
    }
    @Test func acceptedHeartbeatDuringApplySurvivesOperationStartTime() async {
        let fake = FakeFanDevice(), clock = FanTestClock(100), lease = UUID()
        await fake.pauseWrites()
        let controller = FanController(device: fake, clock: { clock.read() })
        let applying = Task { await controller.apply(fixed, leaseID: lease, now: 100) }
        while await fake.writeWaiter == nil { await Task.yield() }
        clock.set(108)
        #expect(await controller.heartbeat(leaseID: lease, now: 108))
        clock.set(115)
        await fake.resumeWrites()
        #expect(await applying.value.phase == .applied)
        #expect(await controller.tick(now: 107).phase == .applied)
        #expect(await controller.tick(now: 115).phase == .applied)
        _ = await controller.restoreSystem()
    }
    @Test func systemModeAloneCannotHideRestoreFailure() async {
        let fake = FakeFanDevice()
        let controller = FanController(device: fake, clock: { 100 })
        _ = await controller.apply(fixed, leaseID: UUID(), now: 100)
        await fake.failRestoreAfterSystemWrite(true)
        let status = await controller.restoreSystem()
        #expect(status.phase == .needsRecovery)
        #expect(status.recoveryIndices == [0, 1])
        #expect(await fake.states.allSatisfy { $0.mode == .system })
        await fake.failRestoreAfterSystemWrite(false)
        #expect(await controller.restoreSystem().phase == .system)
    }
    @Test func editingPresetKeepsPositionAndRejectsNameCollision() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FanPresetStore(url: folder.appendingPathComponent("presets.json"))
        let other = thermal()
        try await store.save([fixed, other])
        let renamed = FanPreset(id: fixed.id, name: "改名", configuration: .fixed(rpm: 3300))
        #expect(try await store.upsert(renamed) == [renamed, other])
        let conflict = FanPreset(id: fixed.id, name: other.name, configuration: .fixed(rpm: 4000))
        do { _ = try await store.upsert(conflict); Issue.record("不能覆盖其他同名方案") } catch {}
        #expect(try await store.load() == [renamed, other])
        let duplicate = FanPreset(name: other.name, configuration: .fixed(rpm: 3000))
        do { _ = try await store.upsert(duplicate); Issue.record("新建同名方案必须拒绝") } catch {}
        #expect(try await store.load() == [renamed, other])
    }
    @Test func deletingPresetPersistsOnlyRequestedIDAndPreservesActiveControl() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FanPresetStore(url: folder.appendingPathComponent("presets.json"))
        let other = thermal()
        try await store.save([fixed, other])
        let device = FakeFanDevice()
        let controller = FanController(device: device, clock: { 100 })
        let active = await controller.apply(fixed, leaseID: UUID(), now: 100)
        let hardwareBefore = await device.states
        #expect(try await store.remove(id: fixed.id) == [other])
        #expect(try await FanPresetStore(url: store.url).load() == [other])
        #expect(try await store.remove(id: fixed.id) == [other])
        #expect(await device.states == hardwareBefore)
        #expect(active.phase == .applied)
        #expect(await controller.tick(now: 101).phase == .applied)
        _ = await controller.restoreSystem()
    }
    @Test func corruptPresetDocumentIsNeverOverwritten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("presets.json"), data = Data("broken".utf8)
        try data.write(to: url)
        let store = FanPresetStore(url: url)
        do { _ = try await store.load(); Issue.record("坏文件应该报错") } catch {}
        do { try await store.save([fixed]); Issue.record("不能覆盖坏文件") } catch {}
        do { _ = try await store.remove(id: fixed.id); Issue.record("删除不能覆盖坏文件") } catch {}
        #expect(try Data(contentsOf: url) == data)
    }
}
