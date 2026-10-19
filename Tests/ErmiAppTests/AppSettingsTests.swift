import XCTest
import ServiceManagement
@testable import Ermi

@MainActor
final class AppSettingsTests: XCTestCase {
    /// 诊断只操作内存替身；不得触发 register、系统设置或真实登录项变更。
    func testLoginItemLifecycle() async throws {
        let fake = LoginItemDiagnosticService()
        let model = AppSettingsModel(loginService: fake.service)
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "Ermi.SettingsDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try check(!model.loginRegistered, "未注册状态错误")
        fake.rejectRegistration = true
        await model.setLoginEnabled(true)
        try check(!model.loginRegistered && model.errorMessage != nil && !model.busy, "注册失败未恢复真实状态")
        fake.rejectRegistration = false
        await model.setLoginEnabled(true)
        try check(model.loginStatus == .requiresApproval && model.loginRegistered && model.errorMessage == nil, "待批准状态错误")
        await model.setLoginEnabled(true)
        try check(fake.registrations == 2, "重复启用发起了额外注册")
        // 模拟用户在系统设置允许或撤销，不通过 UI 开关制造假的已启用状态。
        fake.state = .enabled
        model.refresh()
        try check(model.loginStatus == .enabled, "外部批准未同步")
        fake.state = .requiresApproval
        model.refresh()
        try check(model.loginStatus == .requiresApproval, "外部撤销未同步")

        let removal = Task { await model.setLoginEnabled(false) }
        // 等到替身进入异步注销，验证等待期间不会重复发起系统操作。
        for _ in 0..<100 where fake.pendingRemoval == nil { await Task.yield() }
        guard let pending = fake.pendingRemoval else {
            removal.cancel()
            throw NSError(domain: "Ermi.SettingsDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "异步注销未启动"])
        }
        await model.setLoginEnabled(false)
        await model.setLoginEnabled(true)
        let busyWasCorrect = model.busy && fake.removals == 1 && fake.registrations == 2
        fake.pendingRemoval = nil
        pending.resume(throwing: LoginItemDiagnosticService.Failure.rejected)
        await removal.value
        try check(busyWasCorrect, "异步注销期间未阻止重复操作")
        try check(model.loginRegistered && model.errorMessage != nil && !model.busy, "注销失败未保留真实状态")
        fake.suspendRemoval = false
        await model.setLoginEnabled(false)
        try check(!model.loginRegistered && model.errorMessage == nil && !model.busy, "注销成功未同步")
        await model.setLoginEnabled(false)
        try check(fake.removals == 2, "重复关闭发起了额外注销")
    }
}

@MainActor
private final class LoginItemDiagnosticService {
    enum Failure: Error { case rejected }
    var state: SMAppService.Status = .notRegistered
    var registrations = 0
    var removals = 0
    var rejectRegistration = false
    var suspendRemoval = true
    var pendingRemoval: CheckedContinuation<Void, Error>?
    var service: LoginItemService {
        LoginItemService(status: { self.state }, register: {
            self.registrations += 1
            if self.rejectRegistration { throw Failure.rejected }
            self.state = .requiresApproval
        }, unregister: {
            self.removals += 1
            if self.suspendRemoval {
                try await withCheckedThrowingContinuation { self.pendingRemoval = $0 }
            }
            self.state = .notRegistered
        })
    }
}

