import Foundation
import Testing
import ErmiCore
@testable import Ermi

// 故意使用同步阻塞，确保测试能发现加载意外回到主 actor 后阻塞握手的回归。
final class StartupLoadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var didTimeOut = false
    var timedOut: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didTimeOut
    }
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !released {
            if !condition.wait(until: deadline) { didTimeOut = true; return }
        }
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class StartupConnection: FanControlConnection {
    var usesLocalMode = true
    var localSetupMessage = "尚未授权"
    var ready = true
    var requests: [FanServiceCommand] = []
    var refreshes = 0
    var failure = false
    var replyOverride: FanServiceReply?
    let capability = FanCapability(index: 0, name: "service", minimumRPM: 1200, maximumRPM: 6000)
    func enable() throws {}
    func disconnect() {}
    func refreshAvailability() throws { refreshes += 1 }
    func request(_ command: FanServiceCommand) async throws -> FanServiceReply {
        requests.append(command)
        if failure {
            usesLocalMode = false
            localSetupMessage = "授权已撤销"
            throw CocoaError(.fileReadNoPermission)
        }
        if let replyOverride { return replyOverride }
        return .init(capabilities: [capability], status: .init(phase: .system))
    }
}

@MainActor
struct FanStartupTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test(arguments: [false, true]) func confirmedUnavailableBlocksWritesButAllowsRestore(unsupported: Bool) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = StartupConnection()
        connection.replyOverride = .init(status: .init(phase: .system), error: unsupported ? "不支持写入协议" : nil, capabilityProbeCompleted: true)
        let model = MonitorModel(fanClient: connection, defaults: defaults, loadLocalCapabilities: {
            [.init(index: 0, name: "stale", minimumRPM: 1000, maximumRPM: 6000)]
        }, loadLocalPresets: { [] })
        defer { model.stop() }
        model.start()
        try await waitFor { model.helperReady }
        #expect(model.fanCapabilities.isEmpty)
        #expect(!model.canApplyFanControl)
        #expect(model.isFanless == !unsupported)
        let issue = model.fanCapabilityIssue
        // 心跳和恢复默认携带空能力，不能抹掉 inspect 已确认的无风扇/不支持结果。
        connection.replyOverride = .init(status: .init(phase: .system))
        await model.restoreFanControl()
        #expect(model.fanCapabilityIssue == issue)
        #expect(connection.requests.contains { if case .restore = $0 { return true }; return false })
        model.applyFixedRPM()
        model.selectFanMode(.auto)
        await Task.yield()
        #expect(!connection.requests.contains { if case .apply = $0 { return true }; return false })
        // 用户重试后有效能力可解除阻止，不需要重启应用。
        connection.replyOverride = .init(capabilities: [connection.capability], status: .init(phase: .system), capabilityProbeCompleted: true)
        await model.enableFanControl()
        #expect(model.canApplyFanControl)
        #expect(!model.isFanless)
        #expect(model.fanCapabilities == [connection.capability])
    }

    @Test(arguments: [1, 2, 4]) func fanPresentationUsesActualCapabilityIndices(count: Int) {
        let model = MonitorModel(fanClient: StartupConnection())
        model.fanCapabilities = (0..<count).map { .init(index: $0, name: "Fan \($0)", minimumRPM: 1000, maximumRPM: 6000) }
        #expect(model.displayedFanIndices == Array(0..<count))
        #expect(model.fanRPMText == Array(repeating: "—", count: count).joined(separator: " / ") + " RPM")
    }

    @Test func unreadCapabilitiesAreNotTreatedAsFanless() {
        let model = MonitorModel(fanClient: StartupConnection())
        #expect(model.fanCapabilities.isEmpty)
        #expect(model.fanCapabilityIssue == nil)
        #expect(model.canApplyFanControl)
    }

    @Test func connectionFinishesWhileLocalLoadsAreBlockedAndKeepsServiceCapabilities() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = StartupLoadGate()
        defer { gate.release(); #expect(!gate.timedOut) }
        let connection = StartupConnection()
        let preset = FanPreset(name: "已保存", configuration: .fixed(rpm: 3000))
        let model = MonitorModel(fanClient: connection, defaults: defaults, loadLocalCapabilities: {
            gate.wait()
            return [.init(index: 0, name: "local", minimumRPM: 2000, maximumRPM: 4000)]
        }, loadLocalPresets: {
            gate.wait()
            return [preset]
        })
        defer { model.stop() }
        model.start()
        try await waitFor { model.helperReady }
        #expect(model.fanCapabilities == [connection.capability])
        #expect(model.fanPresets.isEmpty)
        #expect(connection.refreshes == 0)
        if case .inspect? = connection.requests.first {} else { Issue.record("首条请求必须 inspect") }
        gate.release()
        try await waitFor { model.fanPresets.count == 1 }
        #expect(model.fanCapabilities == [connection.capability])
    }

    @Test(arguments: [false, true]) func lateLocalLoadsCannotPublishAfterStopOrSleep(sleep: Bool) async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = StartupLoadGate()
        defer { gate.release(); #expect(!gate.timedOut) }
        let connection = StartupConnection()
        let model = MonitorModel(fanClient: connection, defaults: defaults, loadLocalCapabilities: {
            gate.wait()
            return [.init(index: 0, name: "late", minimumRPM: 2000, maximumRPM: 4000)]
        }, loadLocalPresets: {
            gate.wait()
            return [.init(name: "late", configuration: .fixed(rpm: 3000))]
        })
        defer { model.stop() }
        model.start()
        try await waitFor { model.helperReady }
        if sleep { await model.prepareForSleep() } else { model.stop() }
        model.fanCapabilities = []
        gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.fanCapabilities.isEmpty)
        #expect(model.fanPresets.isEmpty)
        #expect(!model.helperReady)
    }

    @Test func latePresetSnapshotCannotOverwriteSavedPreset() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = StartupLoadGate()
        defer { gate.release(); #expect(!gate.timedOut) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorModel(fanClient: StartupConnection(), defaults: defaults, loadLocalCapabilities: { [] }, loadLocalPresets: {
            gate.wait()
            return []
        }, presetStore: FanPresetStore(url: directory.appendingPathComponent("presets.json")))
        defer { model.stop() }
        model.start()
        try await waitFor { model.helperReady }
        let preset = FanPreset(name: "新方案", configuration: .fixed(rpm: 3000))
        let result = await model.saveFanPreset(preset)
        #expect(result.contains("已保存"))
        gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.fanPresets.map(\.id) == [preset.id])
    }

    @Test func unauthorizedPollingUpdatesSetupWithoutConnectionError() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = StartupConnection()
        connection.ready = false
        connection.failure = true
        let model = MonitorModel(fanClient: connection, defaults: defaults, loadLocalCapabilities: { [] }, loadLocalPresets: { [] })
        defer { model.stop() }
        model.start()
        try await waitFor { model.localFanSetupMessage == "授权已撤销" }
        #expect(!model.usesLocalFanControl)
        #expect(!model.helperReady)
        #expect(!model.controlNeedsAttention)
        #expect(connection.refreshes == 0)
    }
}
