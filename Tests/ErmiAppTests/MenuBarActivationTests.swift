import AppKit
@preconcurrency import ApplicationServices
import Testing
@testable import Ermi

@MainActor
private final class ActivationVisibilityProbe {
    final class Handle {}

    let handle = Handle()
    weak var organizer: MenuBarOrganizer?
    private(set) var activations: [[String]] = []
    private(set) var releases: [ObjectIdentifier] = []
    private(set) var actions: [(UUID, String)] = []
    var running: Set<String> = ["test.folded", "test.hidden", "test.retained", "test.ermi"]

    var access: MenuBarVisibilityAccess {
        MenuBarVisibilityAccess(
            native: true,
            available: { true },
            runningBundleIDs: { self.running },
            ownBundleID: { "test.ermi" },
            activate: { [self] allowed, completion in
                activations.append(allowed)
                // 隐藏状态由真实 Organizer 接收 handle 后建立，不能只伪造 collapsed 属性。
                completion(handle, nil)
            },
            release: { [self] released in
                guard let released = released as? Handle else {
                    Issue.record("释放了不属于本测试的隐藏断言")
                    return
                }
                releases.append(ObjectIdentifier(released))
            }
        )
    }

    func recordAction(_ entry: MenuBarTrayEntry, action: String) {
        // 在 AX 动作执行的那一刻验证，防止“先全部展开、稍后收回”被最终状态检查漏掉。
        #expect(organizer?.collapsed == true)
        #expect(releases.isEmpty)
        #expect(activations.count == 1)
        actions.append((entry.id, action))
    }
}

private actor SuspendedMenuActivation {
    private var actionStarted = false
    private var actionFinished = false
    private var result: CheckedContinuation<Int32, Never>?
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []

    func perform() async -> Int32 {
        actionStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: true) }
        return await withCheckedContinuation { result = $0 }
    }

    func waitUntilStartedOrFinished() async -> Bool {
        if actionStarted { return true }
        if actionFinished { return false }
        return await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(_ status: Int32) {
        result?.resume(returning: status)
        result = nil
    }

    func markFinished() {
        actionFinished = true
        // 回归导致动作被提前拒绝时也唤醒测试，报告失败而不是永久等待 AX 替身。
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: actionStarted) }
    }
}

@MainActor
private final class MenuActivationFixture {
    let suite = "Ermi.MenuBarActivationTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let visibility = ActivationVisibilityProbe()
    let first: MenuBarTrayEntry
    let second: MenuBarTrayEntry
    let hiddenFirst: MenuBarTrayEntry
    let hiddenSecond: MenuBarTrayEntry
    let onlyHidden: Bool
    let tray: MenuBarTray
    let organizer: MenuBarOrganizer

    init(result: Int32 = AXError.success.rawValue, gate: SuspendedMenuActivation? = nil, onlyHidden: Bool = false) {
        self.onlyHidden = onlyHidden
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "icons.enabled")
        preferences.set(onlyHidden ? [] : ["test.folded"], forKey: "icons.folded")
        preferences.set(["test.hidden"], forKey: "icons.hidden")
        // 无效 PID 只占据 AX 类型位置；扫描、权限、身份和动作全部注入，不访问真实菜单栏入口。
        let element = AXUIElementCreateApplication(-1)
        first = MenuBarTrayEntry(pid: -1, bundleID: "test.folded", name: "First", label: "First",
                                element: element, action: kAXPressAction,
                                frame: CGRect(x: 20, y: 0, width: 20, height: 24))
        second = MenuBarTrayEntry(pid: -1, bundleID: "test.folded", name: "Second", label: "Second",
                                 element: element, action: kAXShowMenuAction,
                                 frame: CGRect(x: 60, y: 0, width: 20, height: 24))
        hiddenFirst = MenuBarTrayEntry(pid: -1, bundleID: "test.hidden", name: "Hidden first", label: "Hidden first",
                                      element: element, action: kAXPressAction,
                                      frame: CGRect(x: 40, y: 0, width: 20, height: 24))
        hiddenSecond = MenuBarTrayEntry(pid: -1, bundleID: "test.hidden", name: "Hidden second", label: "Hidden second",
                                       element: element, action: kAXShowMenuAction,
                                       frame: CGRect(x: 80, y: 0, width: 20, height: 24))
        // 扫描主动返回两组的全部入口，验证生产 scope 确实排除 hidden 的每个入口。
        let entries = [hiddenFirst, first, hiddenSecond, second]
        let probe = visibility
        tray = MenuBarTray(
            permissionCheck: { true }, permissionRequest: { true }, identityCheck: { _, _ in true },
            scanOverride: { (entries, [:]) },
            actionOverride: { entry, action in
                await probe.recordAction(entry, action: action)
                if let gate { return await gate.perform() }
                return result
            },
            screenCapturePermissionCheck: { true },
            screenCapturePermissionRequest: { Issue.record("菜单动作测试不应请求录屏权限"); return false },
            iconCaptureOverride: { _ in [:] }
        )
        organizer = MenuBarOrganizer(
            defaults: preferences, permissionCheck: { true }, permissionRequest: { true },
            scanOverride: {
                ([MenuBarApplication(id: "test.folded", name: "Folded", count: 2),
                  MenuBarApplication(id: "test.hidden", name: "Hidden", count: 2),
                  MenuBarApplication(id: "test.retained", name: "Retained", count: 1)], [:])
            },
            tray: tray, visibility: visibility.access
        )
        visibility.organizer = organizer
    }

    func collapse() async {
        // 不调用 start/setEnabled(true)，避免创建真实状态项；仍经过生产扫描、分组和隐藏申请链路。
        await organizer.refresh()
        organizer.collapse()
        // 申请被错误提前拒绝时也应得到断言失败，不能永远等待一个不会发生的 activate 回调。
        while organizer.busy { await Task.yield() }
        #expect(organizer.collapsed)
        #expect(!organizer.busy)
        #expect(visibility.activations.count == 1)
        if let allowed = visibility.activations.first {
            #expect(!allowed.contains("test.hidden"))
            #expect(allowed.contains("test.folded") == onlyHidden)
            #expect(Set(allowed).isSuperset(of: ["test.retained", "test.ermi"]))
        }
        #expect(tray.entries.map(\.id) == (onlyHidden ? [] : [first.id, second.id]))
        #expect(!tray.entries.contains(where: { $0.id == self.hiddenFirst.id || $0.id == self.hiddenSecond.id }))
    }

    func expectStillCollapsed() {
        #expect(organizer.collapsed)
        #expect(!organizer.busy)
        #expect(visibility.releases.isEmpty)
        #expect(visibility.activations.count == 1)
    }

    func showTray() {
        // 仅需要验证用户关闭的用例创建短暂面板；整个 suite 串行，结束时总会关闭。
        _ = NSApplication.shared
        tray.show(anchor: nil)
        #expect(tray.isPresented)
    }

    func cleanup() {
        organizer.stop()
        preferences.removePersistentDomain(forName: suite)
    }
}

@Suite(.serialized)
@MainActor
struct MenuBarActivationTests {
    @Test(arguments: ["test.folded", "test.hidden", "test.retained", "test.unrelated"], [false, true])
    func terminationKeepsOtherIconsCollapsed(exited: String, trayOpen: Bool) async {
        let fixture = MenuActivationFixture()
        defer { fixture.cleanup() }
        await fixture.collapse()
        if trayOpen { fixture.showTray() }
        fixture.visibility.running.remove(exited)

        // 直接驱动 NSWorkspace 退出通知对应的生产入口；断言不能只检查下次点击还能重新收纳。
        fixture.organizer.appsChanged(Notification(name: NSWorkspace.didTerminateApplicationNotification))
        fixture.expectStillCollapsed()
        #expect(fixture.tray.isPresented == trayOpen)
        #expect(!fixture.organizer.applications.contains { $0.id == exited })
        #expect(fixture.tray.entries.map(\.id) == (exited == "test.folded" ? [] : [fixture.first.id, fixture.second.id]))
        #expect(fixture.organizer.folded == ["test.folded"])
        #expect(fixture.organizer.hidden == ["test.hidden"])

        // 设置页每秒轮询也不能因退出留下刷新标记，随后间接解除收纳。
        await fixture.organizer.synchronizePermission()
        fixture.expectStillCollapsed()
        if exited != "test.folded" {
            await fixture.tray.activate(fixture.second)
            #expect(fixture.visibility.actions.first?.0 == fixture.second.id)
            fixture.expectStillCollapsed()
        }
        fixture.organizer.stop()
        #expect(fixture.visibility.releases.count == 1)
    }

    @Test(arguments: [true, false])
    func terminationDuringActionRejectsOnlyTheExitedEntry(exitsSelectedApp: Bool) async throws {
        let gate = SuspendedMenuActivation()
        let fixture = MenuActivationFixture(gate: gate)
        defer { fixture.cleanup() }
        await fixture.collapse()
        fixture.showTray()
        let action = Task {
            await fixture.tray.activate(fixture.first)
            await gate.markFinished()
        }
        try #require(await gate.waitUntilStartedOrFinished())
        fixture.visibility.running.remove(exitsSelectedApp ? "test.folded" : "test.hidden")
        fixture.organizer.appsChanged(Notification(name: NSWorkspace.didTerminateApplicationNotification))
        // 退出动作可能返回 AX 失败；它已从清单消失，不能再留下错误或关闭其他入口的弹窗。
        await gate.finish(exitsSelectedApp ? AXError.invalidUIElement.rawValue : AXError.success.rawValue)
        await action.value
        fixture.expectStillCollapsed()
        #expect(!fixture.tray.loading)
        #expect(!fixture.tray.failed)
        #expect(fixture.tray.isPresented == exitsSelectedApp)
        #expect(fixture.tray.entries.count == (exitsSelectedApp ? 0 : 2))
    }

    @Test func hiddenOnlyGroupCanCollapseWithAnEmptyTray() async {
        let fixture = MenuActivationFixture(onlyHidden: true)
        defer { fixture.cleanup() }
        await fixture.collapse()
        fixture.expectStillCollapsed()
        #expect(fixture.tray.entries.isEmpty)
        #expect(fixture.organizer.folded.isEmpty)
        #expect(fixture.organizer.hidden == ["test.hidden"])

        fixture.organizer.expand()
        #expect(!fixture.organizer.collapsed)
        #expect(fixture.visibility.releases == [ObjectIdentifier(fixture.visibility.handle)])
    }

    @Test func successfulActionKeepsHiddenAssertionUntilExplicitExpand() async {
        let fixture = MenuActivationFixture()
        defer { fixture.cleanup() }
        await fixture.collapse()

        await fixture.tray.activate(fixture.second)

        fixture.expectStillCollapsed()
        #expect(fixture.visibility.actions.count == 1)
        #expect(fixture.visibility.actions.first?.0 == fixture.second.id)
        #expect(fixture.visibility.actions.first?.1 == kAXShowMenuAction)
        #expect(!fixture.tray.isPresented)
        #expect(!fixture.tray.loading)
        #expect(fixture.tray.entries.map(\.id) == [fixture.first.id, fixture.second.id])

        // 正向对照证明监听的是正在使用的 handle：恢复全部显示应释放它，重复恢复不得重复释放。
        fixture.organizer.expand()
        #expect(!fixture.organizer.collapsed)
        #expect(fixture.visibility.releases == [ObjectIdentifier(fixture.visibility.handle)])
        fixture.organizer.expand()
        #expect(fixture.visibility.releases.count == 1)
    }

    @Test func ambiguousActionFailureAndUserDismissKeepIconsHidden() async {
        let fixture = MenuActivationFixture(result: AXError.cannotComplete.rawValue)
        defer { fixture.cleanup() }
        await fixture.collapse()
        fixture.showTray()

        await fixture.tray.activate(fixture.second)

        fixture.expectStillCollapsed()
        #expect(fixture.visibility.actions.count == 1)
        #expect(fixture.tray.failed)
        #expect(!fixture.tray.message.isEmpty)
        #expect(fixture.tray.isPresented)
        #expect(fixture.tray.entries.map(\.id) == [fixture.first.id, fixture.second.id])

        fixture.tray.dismissFromUser()
        fixture.expectStillCollapsed()
        #expect(!fixture.tray.isPresented)
        #expect(fixture.visibility.actions.count == 1)
    }

    @Test(arguments: [AXError.success.rawValue, AXError.cannotComplete.rawValue])
    func dismissDuringActionIgnoresLateSuccessAndFailure(status: Int32) async throws {
        let gate = SuspendedMenuActivation()
        let fixture = MenuActivationFixture(gate: gate)
        defer { fixture.cleanup() }
        await fixture.collapse()
        fixture.showTray()
        let activation = Task {
            await fixture.tray.activate(fixture.second)
            await gate.markFinished()
        }
        try #require(await gate.waitUntilStartedOrFinished())

        fixture.tray.dismissFromUser()
        fixture.expectStillCollapsed()
        #expect(!fixture.tray.isPresented)
        await gate.finish(status)
        await activation.value

        fixture.expectStillCollapsed()
        #expect(!fixture.tray.isPresented)
        #expect(!fixture.tray.loading)
        #expect(!fixture.tray.failed)
        #expect(fixture.visibility.actions.count == 1)
        #expect(fixture.tray.entries.map(\.id) == [fixture.first.id, fixture.second.id])
    }

    @Test(arguments: [false, true])
    func disableOrStopDuringActionReleasesOnceAndNeverRehides(stopping: Bool) async throws {
        let gate = SuspendedMenuActivation()
        let fixture = MenuActivationFixture(gate: gate)
        defer { fixture.cleanup() }
        await fixture.collapse()
        let activation = Task {
            await fixture.tray.activate(fixture.second)
            await gate.markFinished()
        }
        try #require(await gate.waitUntilStartedOrFinished())

        // 用户关闭功能或退出才恢复全部图标；已发出的菜单动作不能在稍后重新接管隐藏状态。
        if stopping { fixture.organizer.stop() }
        else { fixture.organizer.setEnabled(false) }
        #expect(!fixture.organizer.collapsed)
        #expect(fixture.visibility.releases == [ObjectIdentifier(fixture.visibility.handle)])
        #expect(!fixture.tray.isPresented)
        await gate.finish(AXError.success.rawValue)
        await activation.value

        #expect(!fixture.organizer.collapsed)
        #expect(!fixture.organizer.busy)
        #expect(!fixture.tray.isPresented)
        #expect(fixture.tray.entries.isEmpty)
        #expect(fixture.visibility.activations.count == 1)
        #expect(fixture.visibility.releases.count == 1)
        #expect(fixture.visibility.actions.count == 1)
        fixture.organizer.stop()
        #expect(fixture.visibility.releases.count == 1)
    }

    @Test(arguments: ["group", "appsChanged", "launch", "wake"])
    func regroupingAndAppChangesAutomaticallyRestoreConfiguredGroups(trigger: String) async {
        let fixture = MenuActivationFixture()
        defer { fixture.cleanup() }
        await fixture.collapse()

        // 重新分组、启动和唤醒先撤销旧白名单，再按最新清单自动收纳；恢复时不弹出展开栏。
        if trigger != "group" { fixture.visibility.running.insert("test.new") }
        switch trigger {
        case "group":
            #expect(fixture.organizer.setGroup("test.hidden", .folded))
        case "launch", "wake":
            fixture.organizer.appsChanged(Notification(name: trigger == "launch"
                ? NSWorkspace.didLaunchApplicationNotification : NSWorkspace.didWakeNotification))
            await fixture.organizer.synchronizePermission()
        default:
            fixture.organizer.appsChanged()
            await fixture.organizer.synchronizePermission()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while fixture.organizer.busy && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }

        #expect(fixture.organizer.collapsed)
        #expect(!fixture.organizer.busy)
        #expect(fixture.visibility.releases == [ObjectIdentifier(fixture.visibility.handle)])
        #expect(fixture.visibility.activations.count == 2)
        let allowed = Set(fixture.visibility.activations.last ?? [])
        #expect(!allowed.contains("test.folded"))
        #expect(!allowed.contains("test.hidden"))
        #expect(allowed.isSuperset(of: ["test.retained", "test.ermi"]))
        if trigger != "group" { #expect(allowed.contains("test.new")) }
        #expect(fixture.tray.entries.map(\.id) == (trigger == "group"
            ? [fixture.first.id, fixture.hiddenFirst.id, fixture.second.id, fixture.hiddenSecond.id]
            : [fixture.first.id, fixture.second.id]))
        #expect(!fixture.tray.isPresented)
    }

    @Test func explicitRefreshKeepsBothGroupsVisibleUntilTheUserCollapsesAgain() async {
        let fixture = MenuActivationFixture()
        defer { fixture.cleanup() }
        await fixture.collapse()

        // 显式刷新是用户要求重新查看原入口，权限轮询不能随后把它当作自动恢复再隐藏。
        await fixture.organizer.refresh()
        await fixture.organizer.synchronizePermission()

        #expect(!fixture.organizer.collapsed)
        #expect(!fixture.organizer.busy)
        #expect(fixture.visibility.releases == [ObjectIdentifier(fixture.visibility.handle)])
        #expect(fixture.visibility.activations.count == 1)
        #expect(fixture.tray.entries.isEmpty)
        #expect(!fixture.tray.isPresented)
    }
}
