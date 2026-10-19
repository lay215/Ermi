import Foundation
import Testing
@testable import ErmiCore

private enum WriteFixtureError: Error { case denied }
private final class SMCWriteFixture: SMCKeyWriting, @unchecked Sendable {
    var values: [String: SMCValue] = [:]
    var writes: [SMCValue] = []
    var requiresUnlock = false
    var deniedKey: String?
    var delayedModeReads = 0
    var ignoreManualMode = false
    var delayedTargetReads = 0
    var ignoreTarget = false
    private var pendingMode: SMCValue?
    private var pendingTarget: SMCValue?
    init() {
        byte("FNum", 2); byte("Ftst", 0)
        for index in 0..<2 {
            byte("F\(index)Md", 0)
            float("F\(index)Mn", index == 0 ? 1500 : 1600)
            float("F\(index)Mx", index == 0 ? 5000 : 5500)
            float("F\(index)Tg", 0); float("F\(index)Ac", 2100)
        }
        float("Tp09", 60); float("Tg05", 55)
    }
    func byte(_ key: String, _ byte: UInt8) { values[key] = SMCValue(key: key, type: "ui8 ", bytes: [byte]) }
    func float(_ key: String, _ value: Float) {
        let bits = value.bitPattern
        values[key] = SMCValue(key: key, type: "flt ", bytes: (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) })
    }
    func read(_ key: String) throws -> SMCValue {
        if let pendingTarget, pendingTarget.key == key {
            if delayedTargetReads > 0 { delayedTargetReads -= 1 }
            else { values[key] = pendingTarget; self.pendingTarget = nil }
        }
        if let pendingMode, pendingMode.key == key {
            if delayedModeReads > 0 { delayedModeReads -= 1 }
            else { values[key] = pendingMode; self.pendingMode = nil }
        }
        guard let value = values[key] else { throw SMCReadError.missingKey }
        return value
    }
    func write(_ value: SMCValue) throws {
        writes.append(value)
        if value.key == deniedKey { throw WriteFixtureError.denied }
        if requiresUnlock && value.key.hasSuffix("Md") && value.bytes == [1] && values["Ftst"]?.bytes != [1] { throw WriteFixtureError.denied }
        // 模拟驱动接受请求后延迟生效，以及接受请求却不改变模式两种硬件边界。
        if value.key.hasSuffix("Md") {
            if ignoreManualMode && value.bytes == [1] { return }
            if delayedModeReads > 0 { pendingMode = value; return }
        }
        if value.key.hasSuffix("Tg") && (value.number ?? 0) > 0 {
            if ignoreTarget { return }
            if delayedTargetReads > 0 { pendingTarget = value; return }
        }
        if pendingMode?.key == value.key { pendingMode = nil }
        if pendingTarget?.key == value.key { pendingTarget = nil }
        values[value.key] = value
    }
}

struct SMCFanDeviceTests {
    @Test func delayedTargetReadbackWaitsWithoutRewriting() async throws {
        let fixture = SMCWriteFixture()
        fixture.delayedTargetReads = 3
        let device = SMCFanDevice(transport: fixture)
        try await device.setManualRPM(index: 0, rpm: 4000)
        #expect(fixture.values["F0Tg"]?.number == 4000)
        #expect(fixture.writes.map(\.key) == ["F0Md", "F0Tg"])
        try await device.restoreSystem(index: 0)
    }

    @Test func delayedRestoreModeWaitsEvenWhenTaskIsCancelled() async throws {
        let fixture = SMCWriteFixture()
        let device = SMCFanDevice(transport: fixture)
        try await device.setManualRPM(index: 0, rpm: 4000)
        fixture.delayedModeReads = 3
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await device.restoreSystem(index: 0)
        }
        try await task.value
        #expect(fixture.values["F0Md"]?.number == 0)
        #expect(fixture.writes.map(\.key) == ["F0Md", "F0Tg", "F0Md", "F0Tg"])
    }

    @Test func ignoredTargetReportsValueAndRemainsRecoverable() async throws {
        let fixture = SMCWriteFixture()
        fixture.ignoreTarget = true
        let device = SMCFanDevice(transport: fixture)
        do {
            try await device.setManualRPM(index: 0, rpm: 4000)
            Issue.record("目标写入被忽略时不能报告成功")
        } catch {
            #expect(String(describing: error).contains("F0Tg"))
            #expect(String(describing: error).contains("回读=0"))
        }
        try await device.recoverPreviousSession()
        #expect(fixture.values["F0Md"]?.number == 0)
    }

    @Test func delayedModeReadbackIsConfirmedBeforeWritingTarget() async throws {
        let fixture = SMCWriteFixture()
        fixture.values.removeValue(forKey: "Ftst")
        fixture.delayedModeReads = 3
        let device = SMCFanDevice(transport: fixture)
        try await device.setManualRPM(index: 0, rpm: 4000)
        #expect(fixture.writes.map(\.key) == ["F0Md", "F0Tg"])
        #expect(fixture.values["F0Tg"]?.number == 4000)
        try await device.restoreSystem(index: 0)
        #expect(fixture.values["F0Md"]?.number == 0)
    }

    @Test func ignoredModeWriteNeverWritesTargetAndReportsReadback() async throws {
        let fixture = SMCWriteFixture()
        fixture.values.removeValue(forKey: "Ftst")
        fixture.ignoreManualMode = true
        let device = SMCFanDevice(transport: fixture)
        do {
            try await device.setManualRPM(index: 0, rpm: 4000)
            Issue.record("忽略模式写入时不能报告调速成功")
        } catch {
            #expect(String(describing: error).contains("F0Md"))
            #expect(String(describing: error).contains("回读=0"))
        }
        #expect(fixture.writes.map(\.key) == ["F0Md"])
        try await device.recoverPreviousSession()
        #expect(fixture.values["F0Md"]?.number == 0)
    }

    @Test func realDeviceContractReadsRangesModesAndTemperature() async throws {
        let fixture = SMCWriteFixture()
        fixture.byte("F0Md", 3)
        let device = SMCFanDevice(transport: fixture, clock: { 123 })
        let capabilities = try await device.capabilities()
        #expect(capabilities.map(\.minimumRPM) == [1500, 1600])
        let snapshot = try await device.snapshot()
        #expect(snapshot.sampledAt == 123)
        #expect(snapshot.cpuTemperature == 60)
        #expect(snapshot.gpuTemperature == 55)
        #expect(snapshot.fans[0].mode == .system)
        #expect(fixture.writes.isEmpty)
    }

    @Test func refusesNonRootUnknownDeviceInvalidRangeAndOtherOwner() async throws {
        let fixture = SMCWriteFixture()
        let nonRoot = SMCFanDevice(transport: fixture, isRoot: { false })
        await #expect(throws: (any Error).self) { try await nonRoot.setManualRPM(index: 0, rpm: 3000) }
        let unknown = SMCFanDevice(transport: fixture, model: "Unknown")
        await #expect(throws: (any Error).self) { try await unknown.setManualRPM(index: 0, rpm: 3000) }
        let device = SMCFanDevice(transport: fixture)
        for rpm in [1499.0, 5001, Double.nan, Double.infinity, 3000.5] {
            await #expect(throws: (any Error).self) { try await device.setManualRPM(index: 0, rpm: rpm) }
        }
        fixture.byte("F0Md", 1)
        await #expect(throws: (any Error).self) { try await device.setManualRPM(index: 0, rpm: 3000) }
        fixture.byte("F0Md", 0); fixture.byte("Ftst", 1)
        await #expect(throws: (any Error).self) { try await device.setManualRPM(index: 0, rpm: 3000) }
        #expect(fixture.writes.isEmpty)
    }

    @Test func directWriteAndOwnedRestoreUseVerifiedOrdering() async throws {
        let fixture = SMCWriteFixture()
        let device = SMCFanDevice(transport: fixture)
        try await device.setManualRPM(index: 0, rpm: 3200)
        #expect(fixture.writes.map(\.key) == ["F0Md", "F0Tg"])
        #expect(fixture.values["F0Tg"]?.number == 3200)
        try await device.restoreSystem(index: 1)
        #expect(fixture.writes.count == 2)
        try await device.restoreSystem(index: 0)
        #expect(fixture.writes.map(\.key) == ["F0Md", "F0Tg", "F0Md", "F0Tg"])
        #expect(fixture.values["F0Md"]?.number == 0)
        #expect(fixture.values["F0Tg"]?.number == 0)
    }

    @Test func unlockIsReleasedOnlyAfterAllOwnedFansRestore() async throws {
        let fixture = SMCWriteFixture(); fixture.requiresUnlock = true
        let device = SMCFanDevice(transport: fixture)
        try await device.setManualRPM(index: 0, rpm: 3200)
        try await device.setManualRPM(index: 1, rpm: 3300)
        #expect(fixture.values["Ftst"]?.number == 1)
        try await device.restoreSystem(index: 0)
        #expect(fixture.values["Ftst"]?.number == 1)
        try await device.restoreSystem(index: 1)
        #expect(fixture.writes.last?.key == "Ftst")
        #expect(fixture.values["Ftst"]?.number == 0)
    }

    @Test func failedTargetRemainsOwnedAndCanBeRecovered() async throws {
        let fixture = SMCWriteFixture(); fixture.deniedKey = "F0Tg"
        let device = SMCFanDevice(transport: fixture)
        await #expect(throws: (any Error).self) { try await device.setManualRPM(index: 0, rpm: 3200) }
        #expect(fixture.writes.filter { $0.key == "F0Tg" }.count == 3)
        fixture.deniedKey = nil
        try await device.recoverPreviousSession()
        #expect(fixture.values["F0Md"]?.number == 0)
        #expect(fixture.values["F0Tg"]?.number == 0)
    }

    @Test func rejectsUnknownWireFormatsAndSupportsLowercaseAndFPE2() async throws {
        let fixture = SMCWriteFixture()
        fixture.values["F0md"] = fixture.values.removeValue(forKey: "F0Md").map { SMCValue(key: "F0md", type: $0.type, bytes: $0.bytes) }
        fixture.values["F0Tg"] = SMCValue(key: "F0Tg", type: "fpe2", bytes: [0, 0])
        let device = SMCFanDevice(transport: fixture)
        try await device.setManualRPM(index: 0, rpm: 3200)
        #expect(fixture.values["F0Tg"]?.bytes == [0x32, 0])
        #expect(fixture.writes.first?.key == "F0md")
        let bad = SMCWriteFixture()
        bad.values["F0Tg"] = SMCValue(key: "F0Tg", type: "ui32", bytes: [0, 0, 0, 0])
        let invalid = SMCFanDevice(transport: bad)
        await #expect(throws: (any Error).self) { try await invalid.setManualRPM(index: 0, rpm: 3200) }
        #expect(bad.writes.isEmpty)
    }

    @Test func journalFailurePreventsAnyHardwareWriteAndCancelledTaskCanRestore() async throws {
        let fixture = SMCWriteFixture()
        // /dev为既有root目录且非独占700；只读权限检查应拒绝，不能回退到无日志写入。
        let unsafeJournal = SMCFanDevice(transport: fixture, journalURL: URL(fileURLWithPath: "/dev/ermi-test-ownership.json"))
        await #expect(throws: (any Error).self) { try await unsafeJournal.setManualRPM(index: 0, rpm: 3200) }
        #expect(fixture.writes.isEmpty)
        let device = SMCFanDevice(transport: fixture)
        try await device.setManualRPM(index: 0, rpm: 3200)
        let restore = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await device.restoreSystem(index: 0)
        }
        try await restore.value
        #expect(fixture.values["F0Md"]?.number == 0)
        #expect(fixture.values["F0Tg"]?.number == 0)
    }

    @Test func missingUnlockAllowsDirectModeButNeverInventsFallbackKey() async throws {
        let fixture = SMCWriteFixture(); fixture.values.removeValue(forKey: "Ftst")
        let device = SMCFanDevice(transport: fixture)
        try await device.setManualRPM(index: 0, rpm: 3200)
        try await device.restoreSystem(index: 0)
        #expect(fixture.writes.allSatisfy { $0.key != "Ftst" && $0.key != "FTST" })
        let denied = SMCWriteFixture(); denied.values.removeValue(forKey: "Ftst"); denied.requiresUnlock = true
        let blocked = SMCFanDevice(transport: denied)
        await #expect(throws: (any Error).self) { try await blocked.setManualRPM(index: 0, rpm: 3200) }
        #expect(denied.writes.map(\.key) == ["F0Md"])
    }
}
