import Foundation
import Testing
import ErmiCore
@testable import Ermi

@MainActor
private final class SuspendedFanConnection: FanControlConnection {
    var usesLocalMode = true
    var localSetupMessage = "测试连接"
    var ready = false
    var applications = 0
    var restores = 0
    var disconnects = 0
    var pending: CheckedContinuation<FanServiceReply, Error>?
    func enable() throws {}
    func disconnect() { disconnects += 1 }
    func request(_ command: FanServiceCommand) async throws -> FanServiceReply {
        switch command {
        case .apply: applications += 1
        case .restore: restores += 1
        default: return .init(status: .init(phase: .system))
        }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ reply: FanServiceReply) { let replyTo = pending; pending = nil; replyTo?.resume(returning: reply) }
}

@MainActor
struct MonitorLifecycleTests {
    private let preset = FanPreset(name: "测试", configuration: .fixed(rpm: 3200))

    @Test func queuedApplyCannotStartAfterSleepAndWakeDoesNotReapply() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = SuspendedFanConnection()
        let model = MonitorModel(fanClient: connection, defaults: defaults)
        model.helperReady = true
        // apply 创建的任务尚未调度，睡眠必须在它建立连接前使它失效。
        model.applyFanPreset(preset)
        await model.prepareForSleep()
        for _ in 0..<20 { await Task.yield() }
        #expect(connection.applications == 0)
        model.applyFanPreset(preset)
        #expect(!model.controlBusy)
        model.resumeAfterSleep()
        for _ in 0..<20 { await Task.yield() }
        #expect(connection.applications == 0)
        model.stop()
    }

    @Test func inFlightApplyCannotPublishAfterSleep() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = SuspendedFanConnection()
        let model = MonitorModel(fanClient: connection, defaults: defaults)
        model.helperReady = true
        model.applyFanPreset(preset)
        for _ in 0..<100 where connection.pending == nil { await Task.yield() }
        #expect(connection.applications == 1)
        try #require(connection.pending != nil)
        await model.prepareForSleep()
        #expect(connection.disconnects == 1)
        connection.finish(.init(status: .init(phase: .applied, preset: preset)))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.fanStatus.phase == .system)
        #expect(model.pendingFanMode == nil)
        #expect(!model.controlBusy)
        #expect(!model.helperReady)
        model.stop()
    }

    @Test func busyRestoreReplyStillDisconnectsBeforeSleep() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = SuspendedFanConnection()
        let model = MonitorModel(fanClient: connection, defaults: defaults)
        model.helperReady = true
        model.fanStatus = .init(phase: .applied, preset: preset)
        let sleep = Task { await model.prepareForSleep() }
        for _ in 0..<100 where connection.pending == nil { await Task.yield() }
        try #require(connection.pending != nil)
        connection.finish(.init(error: "控制操作尚在进行，请稍后恢复"))
        await sleep.value
        #expect(connection.disconnects == 1)
        #expect(model.fanStatus.phase == .applied)
        #expect(model.controlNeedsAttention)
        model.stop()
    }

    @Test func lateSleepReplyCannotDisconnectAwakenedSession() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = SuspendedFanConnection()
        let model = MonitorModel(fanClient: connection, defaults: defaults)
        model.helperReady = true
        let sleep = Task { await model.prepareForSleep() }
        for _ in 0..<100 where connection.pending == nil { await Task.yield() }
        try #require(connection.pending != nil)
        model.resumeAfterSleep()
        let wakeDisconnects = connection.disconnects
        model.controlNotice = "新会话"
        connection.finish(.init(error: "旧恢复请求失败"))
        await sleep.value
        #expect(connection.disconnects == wakeDisconnects)
        #expect(model.controlNotice != "旧恢复请求失败")
        #expect(connection.applications == 0)
        model.stop()
    }
    @Test func modeSelectionRespondsBeforeDeviceConfirmationAndRevertsOnFailure() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = SuspendedFanConnection()
        let model = MonitorModel(fanClient: connection, defaults: defaults)
        model.helperReady = true
        model.selectFanMode(.fixed)
        // 不用等待任务调度或设备回包，就应反馈点击；硬件状态不能提前报成功。
        #expect(model.displayedFanMode == .fixed)
        #expect(model.fanMode == .system)
        #expect(model.fanControlBadge == "正在应用…")
        for _ in 0..<100 where connection.pending == nil { await Task.yield() }
        try #require(connection.pending != nil)
        model.selectFanMode(.auto)
        connection.finish(.init(error: "设备拒绝"))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.pendingFanMode == nil)
        #expect(model.displayedFanMode == .system)
        #expect(model.controlNeedsAttention)
        #expect(connection.applications == 1)
        model.stop()
    }

    @Test func restoreSelectionIsImmediateAndCannotOverlapAnotherClick() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = SuspendedFanConnection()
        let model = MonitorModel(fanClient: connection, defaults: defaults)
        model.helperReady = true
        model.fanMode = .fixed
        model.selectFanMode(.system)
        #expect(model.displayedFanMode == .system)
        #expect(model.fanMode == .fixed)
        #expect(model.controlBusy)
        #expect(model.fanControlBadge == "正在交还系统…")
        model.selectFanMode(.system)
        for _ in 0..<100 where connection.pending == nil { await Task.yield() }
        try #require(connection.pending != nil)
        #expect(connection.restores == 1)
        #expect(connection.applications == 0)
        connection.finish(.init(status: .init(phase: .system)))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.pendingFanMode == nil)
        #expect(model.fanMode == .system)
        #expect(!model.controlBusy)
        model.stop()
    }

    @Test func rapidModeClicksKeepLatestSelectionAndSerializeHardwareWrites() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = SuspendedFanConnection()
        let model = MonitorModel(fanClient: connection, defaults: defaults)
        model.helperReady = true
        model.selectFanMode(.fixed)
        for _ in 0..<100 where connection.pending == nil { await Task.yield() }
        try #require(connection.pending != nil)
        model.selectFanMode(.auto)
        model.selectFanMode(.system)
        #expect(model.displayedFanMode == .system)
        #expect(connection.applications == 1)
        #expect(connection.restores == 0)
        connection.finish(.init(status: .init(phase: .applied, preset: preset)))
        for _ in 0..<100 where connection.restores == 0 { await Task.yield() }
        #expect(connection.applications == 1)
        #expect(connection.restores == 1)
        connection.finish(.init(status: .init(phase: .system)))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.pendingFanMode == nil)
        #expect(model.fanMode == .system)
        model.stop()
    }

}
