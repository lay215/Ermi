import Foundation
import Testing
import ErmiCore
@testable import Ermi

@MainActor
private final class AuthorizationFanConnection: FanControlConnection {
    var usesLocalMode = true
    var localSetupMessage = "待授权"
    var ready = false
    var enables = 0
    var applications = 0
    var restores = 0
    func enable() throws { enables += 1; ready = true }
    func disconnect() {}
    func request(_ command: FanServiceCommand) async throws -> FanServiceReply {
        switch command {
        case .apply: applications += 1
        case .restore: restores += 1
        default: break
        }
        return .init(status: .init(phase: .system))
    }
}

@MainActor
struct FanAuthorizationEntryTests {
    @Test func unreadyControlsOpenInstallerWithoutWritingOrReplaying() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = AuthorizationFanConnection()
        var installations = 0
        let model = MonitorModel(fanClient: connection, defaults: defaults, launchLocalInstaller: { _ in installations += 1 })
        model.selectFanMode(.fixed)
        for _ in 0..<30 { await Task.yield() }
        #expect(installations == 1)
        #expect(connection.enables == 1)
        #expect(connection.applications == 0)
        #expect(connection.restores == 0)
        #expect(model.fanMode == .system)
        #expect(model.helperReady)
        model.stop()
    }

    @Test func signedServiceUsesEnableWithoutLocalInstallerOrAutomaticApply() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = AuthorizationFanConnection()
        connection.usesLocalMode = false
        var installations = 0
        let model = MonitorModel(fanClient: connection, defaults: defaults, launchLocalInstaller: { _ in installations += 1 })
        model.selectFanMode(.fixed)
        for _ in 0..<20 { await Task.yield() }
        #expect(connection.enables == 1)
        #expect(installations == 0)
        #expect(connection.applications == 0)
        #expect(model.helperReady)
        model.selectFanMode(.fixed)
        for _ in 0..<20 { await Task.yield() }
        #expect(connection.applications == 1)
        model.stop()
    }

    @Test func automaticRestoreAndSleepingClicksDoNotOpenAuthorization() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = AuthorizationFanConnection()
        var installations = 0
        let model = MonitorModel(fanClient: connection, defaults: defaults, launchLocalInstaller: { _ in installations += 1 })
        await model.restoreFanControl()
        await model.prepareForSleep()
        model.selectFanMode(.fixed)
        for _ in 0..<20 { await Task.yield() }
        #expect(installations == 0)
        #expect(connection.enables == 0)
        #expect(connection.applications == 0)
        model.stop()
    }
    @Test func installerOpeningRemainsResponsiveDeduplicatesAndReportsFailure() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = AuthorizationFanConnection()
        var continuation: CheckedContinuation<Void, Error>?
        var installations = 0
        let model = MonitorModel(fanClient: connection, defaults: defaults, launchLocalInstaller: { _ in
            installations += 1
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        model.openLocalFanInstaller()
        #expect(model.installerOpening)
        #expect(model.controlNotice == "请在系统窗口确认安装…")
        for _ in 0..<20 { await Task.yield() }
        model.openLocalFanInstaller()
        // 外部授权入口迟迟不回调时，MainActor 仍能处理界面状态和再次点击。
        model.detailPage = .monitor
        #expect(installations == 1)
        #expect(!model.controlBusy)
        continuation?.resume(throwing: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "启动失败"]))
        for _ in 0..<20 { await Task.yield() }
        #expect(!model.installerOpening)
        #expect(model.controlNotice.contains("启动失败"))
        #expect(model.controlNeedsAttention)
        model.stop()
    }

    @Test func uninstallDoesNotReconnectOrReinstall() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = AuthorizationFanConnection()
        var uninstallRequested = false
        let model = MonitorModel(fanClient: connection, defaults: defaults, launchLocalInstaller: { uninstall in uninstallRequested = uninstall })
        model.openLocalFanInstaller(uninstall: true)
        for _ in 0..<30 { await Task.yield() }
        #expect(uninstallRequested)
        #expect(connection.enables == 0)
        #expect(!model.helperReady)
        #expect(model.controlNotice.contains("已卸载"))
        model.stop()
    }

    @Test func cancelledAuthorizationDoesNotReconnectOrReportFailure() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = AuthorizationFanConnection()
        let model = MonitorModel(fanClient: connection, defaults: defaults, launchLocalInstaller: { _ in throw LocalFanInstallerError.cancelled })
        model.openLocalFanInstaller()
        for _ in 0..<30 { await Task.yield() }
        #expect(connection.enables == 0)
        #expect(!model.controlNeedsAttention)
        #expect(model.controlNotice == "已取消安装。")
        model.stop()
    }

    @Test func installationFinishingAfterSleepDoesNotConnect() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = AuthorizationFanConnection()
        var continuation: CheckedContinuation<Void, Error>?
        let model = MonitorModel(fanClient: connection, defaults: defaults, launchLocalInstaller: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        model.openLocalFanInstaller()
        for _ in 0..<20 { await Task.yield() }
        await model.prepareForSleep()
        continuation?.resume()
        for _ in 0..<30 { await Task.yield() }
        #expect(connection.enables == 0)
        #expect(!model.installerOpening)
        model.stop()
    }

    @Test func nativeInstallerResultDistinguishesCancellationAndFailure() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try LocalFanInstallerClient.validateResult(status: 0, output: "installed")
        #expect(throws: LocalFanInstallerError.self) {
            try LocalFanInstallerClient.validateResult(status: 0, output: "ERMI_AUTH_CANCELLED\n")
        }
        #expect(throws: LocalFanInstallerError.self) {
            try LocalFanInstallerClient.validateResult(status: 1, output: "signature mismatch")
        }
    }

}
