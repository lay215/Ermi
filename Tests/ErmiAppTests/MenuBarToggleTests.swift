import AppKit
@preconcurrency import ApplicationServices
import Testing
@testable import Ermi

// 扫描与截图替身刻意不响应 Task.cancel，以验证跨进程结果迟到时仍由生产流程拒绝回填。
private actor TogglePreparationGate {
    private var holding: Bool
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    private(set) var completed = 0

    init(holding: Bool = false) { self.holding = holding }

    func pass() async -> Int {
        let ordinal = started + 1
        started += 1
        if holding {
            await withCheckedContinuation { pending.append($0) }
        }
        completed += 1
        return ordinal
    }

    func releaseAll() {
        holding = false
        let continuations = pending
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

@MainActor
private final class ToggleVisibilityProbe {
    final class Handle {}

    let holding: Bool
    private(set) var allowedBundles: [[String]] = []
    private(set) var handles: [Handle] = []
    private(set) var releases: [ObjectIdentifier] = []
    private var completions: [Int: @MainActor (Any?, Error?) -> Void] = [:]

    init(holding: Bool = false) { self.holding = holding }

    var access: MenuBarVisibilityAccess {
        MenuBarVisibilityAccess(
            native: true, available: { true },
            runningBundleIDs: { ["test.folded", "test.retained", "test.ermi"] },
            ownBundleID: { "test.ermi" },
            activate: { [self] allowed, completion in
                let index = allowedBundles.count
                allowedBundles.append(allowed)
                let handle = Handle()
                handles.append(handle)
                if holding { completions[index] = completion }
                else { completion(handle, nil) }
            },
            release: { [self] handle in
                guard let handle = handle as? Handle else {
                    Issue.record("释放了不属于单击入口测试的隐藏断言")
                    return
                }
                releases.append(ObjectIdentifier(handle))
            }
        )
    }

    func completeAll() {
        let pending = completions
        completions.removeAll()
        for (index, completion) in pending { completion(handles[index], nil) }
    }
}

@MainActor
private func toggleEventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
    // 仅等待被测异步流程推进；回归导致事件根本不发生时报告失败，不能让测试永久挂起。
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}

@MainActor
private final class MenuBarToggleFixture {
    let suite = "Ermi.MenuBarToggleTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let inventory: TogglePreparationGate
    let entryScan = TogglePreparationGate()
    let capture: TogglePreparationGate
    let visibility: ToggleVisibilityProbe
    let entry: MenuBarTrayEntry
    let tray: MenuBarTray
    let organizer: MenuBarOrganizer

    init(holding phase: String? = nil, emptyFirstInventory: Bool = false,
         enabled: Bool = true, folded: [String] = ["test.folded"], authorized: Bool = true,
         permissionCheck: (() -> Bool)? = nil) {
        // 只创建样本面板所需的 AppKit 环境；不调用 start，也不创建真实菜单栏状态项。
        _ = NSApplication.shared
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(enabled, forKey: "icons.enabled")
        preferences.set(folded, forKey: "icons.folded")
        inventory = TogglePreparationGate(holding: phase == "inventory")
        capture = TogglePreparationGate(holding: phase == "capture")
        visibility = ToggleVisibilityProbe(holding: phase == "activation")
        entry = MenuBarTrayEntry(
            pid: -1, bundleID: "test.folded", name: "Folded", label: "Sample item",
            element: AXUIElementCreateApplication(-1), action: kAXPressAction,
            frame: CGRect(x: 100, y: 0, width: 24, height: 24)
        )
        let inventory = self.inventory
        let entryScan = self.entryScan
        let capture = self.capture
        let entries = [entry]
        tray = MenuBarTray(
            permissionCheck: { true },
            permissionRequest: { Issue.record("单击入口测试不应请求真实辅助权限"); return false },
            identityCheck: { _, _ in true },
            scanOverride: { _ = await entryScan.pass(); return (entries, [:]) },
            actionOverride: { _, _ in
                Issue.record("打开或关闭展开栏不应执行任何菜单栏入口")
                return AXError.failure.rawValue
            },
            screenCapturePermissionCheck: { true },
            screenCapturePermissionRequest: { Issue.record("单击入口测试不应请求录屏权限"); return false },
            iconCaptureOverride: { _ in _ = await capture.pass(); return [:] }
        )
        organizer = MenuBarOrganizer(
            defaults: preferences, permissionCheck: permissionCheck ?? { authorized },
            permissionRequest: { Issue.record("单击入口测试不应请求系统授权"); return false },
            scanOverride: {
                let ordinal = await inventory.pass()
                if emptyFirstInventory && ordinal == 1 { return ([], [:]) }
                return ([MenuBarApplication(id: "test.folded", name: "Folded \(ordinal)", count: 1)], [:])
            },
            tray: tray, visibility: visibility.access
        )
    }

    func waitForPhase(_ phase: String) async throws {
        switch phase {
        case "inventory":
            try #require(await toggleEventually { await self.inventory.started == 1 })
        case "capture":
            try #require(await toggleEventually { await self.capture.started == 1 })
        default:
            try #require(await toggleEventually { self.visibility.allowedBundles.count == 1 })
        }
    }

    func releasePhase(_ phase: String) async {
        switch phase {
        case "inventory": await inventory.releaseAll()
        case "capture": await capture.releaseAll()
        default: visibility.completeAll()
        }
    }

    func cancelOpening(with action: String) async throws {
        switch action {
        case "expand": organizer.expand()
        case "disable": organizer.setEnabled(false)
        case "stop": organizer.stop()
        default:
            let previousScans = await inventory.started
            let refresh = Task { await organizer.refresh() }
            try #require(await toggleEventually { await self.inventory.started > previousScans })
            // 显式刷新可以重新读取清单，但它不应继承旧 toggle 的打开意图。
            await inventory.releaseAll()
            await refresh.value
        }
    }

    func expectOpened(activationCount: Int = 1) async throws {
        try #require(await toggleEventually { self.tray.isPresented && !self.organizer.busy })
        #expect(organizer.collapsed)
        #expect(organizer.trayPresented)
        #expect(tray.entries.map(\.id) == [entry.id])
        #expect(visibility.allowedBundles.count == activationCount)
        if let allowed = visibility.allowedBundles.last {
            #expect(!allowed.contains("test.folded"))
            #expect(Set(allowed).isSuperset(of: ["test.retained", "test.ermi"]))
        }
    }

    func expectLateResultDoesNotReopen() async {
        // 取消已经同步关闭；再让迟到 continuation 与后续主队列任务实际跑过，持续检查不会重新弹出。
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(100))
        while clock.now < deadline {
            #expect(!tray.isPresented)
            #expect(!organizer.collapsed)
            #expect(!organizer.busy)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func statusButton() -> NSStatusBarButton? {
        func find(in view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton, button.target === self.organizer { return button }
            for child in view.subviews {
                if let button = find(in: child) { return button }
            }
            return nil
        }
        for window in NSApp.windows {
            if let content = window.contentView, let button = find(in: content) { return button }
        }
        return nil
    }

    func cleanup() {
        organizer.stop()
        visibility.completeAll()
        preferences.removePersistentDomain(forName: suite)
        let inventory = self.inventory
        let entryScan = self.entryScan
        let capture = self.capture
        // 断言失败也必须释放替身中的 continuation；stop 已使任何迟到结果失效。
        Task {
            await inventory.releaseAll()
            await entryScan.releaseAll()
            await capture.releaseAll()
        }
    }
}

@Suite(.serialized)
@MainActor
struct MenuBarToggleTests {
    @Test(arguments: [false, true])
    func permissionGrantResumesAutomaticCollapseUnlessStopped(stopDuringScan: Bool) async throws {
        var authorized = false
        let fixture = MenuBarToggleFixture(holding: "inventory", permissionCheck: { authorized })
        defer { fixture.cleanup() }
        fixture.organizer.setEnabled(true, requestPermissionIfNeeded: false)
        #expect(!fixture.organizer.busy)
        #expect(fixture.visibility.allowedBundles.isEmpty)
        authorized = true
        let sync = Task { await fixture.organizer.synchronizePermission() }
        try await fixture.waitForPhase("inventory")
        if stopDuringScan { fixture.organizer.stop() }
        await fixture.releasePhase("inventory")
        await sync.value
        if stopDuringScan {
            await fixture.expectLateResultDoesNotReopen()
            #expect(fixture.visibility.allowedBundles.isEmpty)
        } else {
            try #require(await toggleEventually { fixture.organizer.collapsed && !fixture.organizer.busy })
            #expect(!fixture.tray.isPresented)
            #expect(fixture.visibility.allowedBundles.count == 1)
        }
    }

    @Test(arguments: ["disabled", "empty", "unauthorized"])
    func startupWithoutEligibleConfigurationDoesNotHideOrRequestPermission(reason: String) async {
        let fixture = MenuBarToggleFixture(enabled: reason != "disabled",
                                          folded: reason == "empty" ? [] : ["test.folded"],
                                          authorized: reason != "unauthorized")
        defer { fixture.cleanup() }
        fixture.organizer.start()
        await fixture.expectLateResultDoesNotReopen()
        #expect(fixture.visibility.allowedBundles.isEmpty)
        #expect(await fixture.inventory.started == 0)
    }

    @Test(arguments: ["inventory", "capture", "activation"], ["expand", "disable", "stop"])
    func cancellingAutomaticCollapseRejectsLateResults(phase: String, action: String) async throws {
        let fixture = MenuBarToggleFixture(holding: phase)
        defer { fixture.cleanup() }
        fixture.organizer.setEnabled(true, requestPermissionIfNeeded: false)
        try await fixture.waitForPhase(phase)
        try await fixture.cancelOpening(with: action)
        await fixture.releasePhase(phase)
        await fixture.expectLateResultDoesNotReopen()
        if phase == "activation" {
            let handle = try #require(fixture.visibility.handles.first)
            #expect(fixture.visibility.releases == [ObjectIdentifier(handle)])
        } else { #expect(fixture.visibility.allowedBundles.isEmpty) }
    }

    @Test(arguments: ["inventory", "capture", "activation"])
    func clickingDuringAutomaticCollapseOpensTheSamePreparedTray(phase: String) async throws {
        let fixture = MenuBarToggleFixture(holding: phase)
        defer { fixture.cleanup() }
        fixture.organizer.setEnabled(true, requestPermissionIfNeeded: false)
        try await fixture.waitForPhase(phase)
        fixture.organizer.toggle()
        await fixture.releasePhase(phase)
        try await fixture.expectOpened()
        #expect(await fixture.inventory.started == 1)
    }

    @Test func lateCreatedStatusItemAutomaticallyCollapsesButManualExpandStaysExpanded() async throws {
        let fixture = MenuBarToggleFixture(emptyFirstInventory: true)
        defer { fixture.cleanup() }
        fixture.organizer.setEnabled(true, requestPermissionIfNeeded: false)
        // 启动通知发生时图标尚未创建；没有第二次通知或点击，也应在短暂补读后自动收纳。
        try #require(await toggleEventually { fixture.organizer.collapsed && !fixture.organizer.busy })
        #expect(!fixture.tray.isPresented)
        #expect(await fixture.inventory.started == 2)
        fixture.organizer.expand()
        fixture.organizer.appsChanged(Notification(name: NSWorkspace.didWakeNotification))
        await fixture.organizer.synchronizePermission()
        await fixture.expectLateResultDoesNotReopen()
        #expect(fixture.visibility.allowedBundles.count == 1)
    }

    @Test(arguments: ["space", "display"])
    func layoutChangesDuringStartupResumeSilently(change: String) async throws {
        let fixture = MenuBarToggleFixture(holding: "inventory")
        defer { fixture.cleanup() }
        fixture.organizer.start()
        try await fixture.waitForPhase("inventory")
        fixture.organizer.toggle()
        if change == "space" {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        } else {
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        try #require(await toggleEventually { await fixture.inventory.started == 2 })
        await fixture.releasePhase("inventory")
        try #require(await toggleEventually { fixture.organizer.collapsed && !fixture.organizer.busy })
        #expect(!fixture.tray.isPresented)
        #expect(fixture.visibility.allowedBundles.count == 1)
    }

    @Test(arguments: ["start", "enable"])
    func savedGroupsCollapseWithoutClickingArrow(trigger: String) async throws {
        let fixture = MenuBarToggleFixture()
        defer { fixture.cleanup() }
        // 从真实启动/启用入口验证保存的收起组自动应用；不能用主动 toggle 替代默认行为。
        if trigger == "start" { fixture.organizer.start() }
        else { fixture.organizer.setEnabled(true, requestPermissionIfNeeded: false) }
        try #require(await toggleEventually { fixture.organizer.collapsed && !fixture.organizer.busy })
        #expect(!fixture.tray.isPresented)
        #expect(fixture.visibility.allowedBundles.count == 1)
        #expect(fixture.visibility.allowedBundles.first?.contains("test.folded") == false)
        #expect(await fixture.inventory.started == 1)
        #expect(await fixture.entryScan.started == 1)
        // 默认收纳完成后，首次点击只打开已有展开栏，不再重复扫描或申请断言。
        fixture.organizer.toggle()
        try await fixture.expectOpened()
        #expect(await fixture.inventory.started == 1)
    }

    @Test func nativeStatusButtonUsesFullHitAreaAndSpinnerDoesNotInterceptClicks() async throws {
        let fixture = MenuBarToggleFixture(holding: "inventory")
        defer { fixture.cleanup() }
        // 仅此用例安装自己的状态项；隐藏申请仍完全注入，结束时 stop 移除状态项和观察者。
        fixture.organizer.start()
        try #require(await toggleEventually { fixture.statusButton() != nil })
        let button = try #require(fixture.statusButton())
        button.window?.layoutIfNeeded()
        button.layoutSubtreeIfNeeded()
        // 系统可在原生按钮边界保留半个 point；宿主窗口还包含非按钮区域，不能用它的高度作命中契约。
        #expect(abs(button.bounds.width - 24) <= 0.5)
        #expect(abs(button.bounds.height - NSStatusBar.system.thickness) <= 0.5)

        func expectFullHitArea() {
            // hitTest 的输入是父视图坐标；四角与中心均属于原生按钮，命中不能只覆盖箭头或转圈。
            for x in [CGFloat(1), button.bounds.midX, button.bounds.maxX - 1] {
                for y in [CGFloat(1), button.bounds.midY, button.bounds.maxY - 1] {
                    let point = button.convert(NSPoint(x: x, y: y), to: button.superview)
                    #expect(button.hitTest(point) === button)
                }
            }
        }
        func sendButtonAction() throws {
            let action = try #require(button.action)
            let target = try #require(button.target as? MenuBarOrganizer)
            #expect(target === fixture.organizer)
            // 验证已安装按钮的真实 target/action 路由；不调用包含按压表现的 performClick，也不合成鼠标事件。
            try #require(NSApp.sendAction(action, to: target, from: button))
        }
        expectFullHitArea()
        try sendButtonAction()
        #expect(fixture.organizer.busy)
        try await fixture.waitForPhase("inventory")
        let indicator = try #require(button.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        // AppKit 可把 nil image 替换成 1×1 占位图；加载态应检查真正显示的转圈，不依赖内部占位表示。
        #expect(!indicator.isHiddenOrHasHiddenAncestor)
        // swift test 的状态项宿主可暂时为零高度；检查按钮内的真实布局，实屏可见性不能用此宿主推断。
        #expect(!indicator.bounds.isEmpty)
        #expect(button.bounds.contains(indicator.frame))
        #expect(button.accessibilityLabel() == L("正在准备展开栏"))
        #expect(indicator.hitTest(NSPoint(x: indicator.frame.midX, y: indicator.frame.midY)) == nil)
        expectFullHitArea()
        try sendButtonAction()
        #expect(fixture.organizer.busy)
        await fixture.releasePhase("inventory")
        try await fixture.expectOpened()
        #expect(await fixture.inventory.started == 1)

        #expect(button.image?.isTemplate == true)
        #expect(button.accessibilityLabel() == L("收起展开栏"))
        try sendButtonAction()
        #expect(!fixture.tray.isPresented)
        #expect(fixture.organizer.collapsed)
        #expect(fixture.visibility.releases.isEmpty)
        #expect(button.accessibilityLabel() == L("展开收纳图标"))
    }

    @Test func firstOrdinaryClickPreparesAndOpensWithoutVisitingSettings() async throws {
        let fixture = MenuBarToggleFixture()
        defer { fixture.cleanup() }
        #expect(fixture.organizer.applications.isEmpty)
        #expect(!fixture.organizer.collapsed)

        fixture.organizer.toggle()
        #expect(fixture.organizer.busy)
        try await fixture.expectOpened()
        #expect(await fixture.inventory.started == 1)
        #expect(await fixture.entryScan.started == 1)
        #expect(await fixture.capture.started == 1)

        // 第二次普通点击只关横条；再次打开复用同一断言与入口快照，不能重新扫描或释放隐藏。
        fixture.organizer.toggle()
        #expect(!fixture.tray.isPresented)
        #expect(fixture.organizer.collapsed)
        #expect(fixture.visibility.releases.isEmpty)
        fixture.organizer.toggle()
        try await fixture.expectOpened()
        #expect(await fixture.inventory.started == 1)
        #expect(await fixture.entryScan.started == 1)
        #expect(await fixture.capture.started == 1)
        #expect(fixture.visibility.releases.isEmpty)
    }

    @Test func cancelledRefreshThatHasNotStartedDoesNotCancelNewOpening() async throws {
        let fixture = MenuBarToggleFixture(holding: "inventory")
        defer { fixture.cleanup() }
        // 同一 MainActor turn 内取消尚未启动的刷新，再单击；旧任务不能先恢复全部图标并撤销新打开。
        let oldRefresh = Task { await fixture.organizer.refresh() }
        oldRefresh.cancel()
        fixture.organizer.toggle()
        #expect(fixture.organizer.busy)

        try await fixture.waitForPhase("inventory")
        await fixture.releasePhase("inventory")
        await oldRefresh.value
        try await fixture.expectOpened()
        #expect(await fixture.inventory.started == 1)
        #expect(await fixture.entryScan.started == 1)
        #expect(await fixture.capture.started == 1)
        #expect(fixture.visibility.releases.isEmpty)
    }

    @Test func nextOrdinaryClickRetriesAfterEmptyInventory() async throws {
        let fixture = MenuBarToggleFixture(emptyFirstInventory: true)
        defer { fixture.cleanup() }
        fixture.organizer.toggle()
        #expect(fixture.organizer.busy)
        try #require(await toggleEventually {
            let completed = await fixture.inventory.completed
            return completed == 1 && !fixture.organizer.busy
        })
        #expect(fixture.organizer.applications.isEmpty)
        #expect(!fixture.organizer.collapsed)
        #expect(!fixture.tray.isPresented)
        #expect(fixture.visibility.allowedBundles.isEmpty)
        #expect(await fixture.entryScan.started == 0)

        // 完整扫描得到空清单也可以结束等待；下一次主动点击必须再扫描，而不是永久沿用空结果。
        fixture.organizer.toggle()
        #expect(fixture.organizer.busy)
        try await fixture.expectOpened()
        #expect(await fixture.inventory.started == 2)
        #expect(await fixture.entryScan.started == 1)
        #expect(await fixture.capture.started == 1)
        #expect(fixture.organizer.applications.first?.name == "Folded 2")
        #expect(fixture.visibility.releases.isEmpty)
    }

    @Test(arguments: ["inventory", "capture", "activation"])
    func repeatedClicksWhilePreparingCoalesceIntoOneOpen(phase: String) async throws {
        let fixture = MenuBarToggleFixture(holding: phase)
        defer { fixture.cleanup() }
        fixture.organizer.toggle()
        #expect(fixture.organizer.busy)
        try await fixture.waitForPhase(phase)

        for _ in 0..<3 {
            fixture.organizer.toggle()
            #expect(fixture.organizer.busy)
        }
        #expect(!fixture.tray.isPresented)
        #expect(fixture.visibility.releases.isEmpty)
        #expect(await fixture.inventory.started == 1)
        await fixture.releasePhase(phase)
        try await fixture.expectOpened()
        #expect(await fixture.inventory.started == 1)
        #expect(await fixture.entryScan.started == 1)
        #expect(await fixture.capture.started == 1)
        #expect(fixture.visibility.releases.isEmpty)
    }

    @Test(arguments: ["inventory", "capture", "activation"], ["expand", "refresh", "disable", "stop"])
    func explicitCancellationRejectsLateOpeningResults(phase: String, action: String) async throws {
        let fixture = MenuBarToggleFixture(holding: phase)
        defer { fixture.cleanup() }
        fixture.organizer.toggle()
        try await fixture.waitForPhase(phase)

        try await fixture.cancelOpening(with: action)
        #expect(!fixture.tray.isPresented)
        #expect(!fixture.organizer.busy)
        await fixture.releasePhase(phase)
        await fixture.expectLateResultDoesNotReopen()
        #expect(fixture.tray.entries.isEmpty)
        if phase == "activation" {
            #expect(fixture.visibility.allowedBundles.count == 1)
            let handle = try #require(fixture.visibility.handles.first)
            #expect(fixture.visibility.releases == [ObjectIdentifier(handle)])
        } else {
            #expect(fixture.visibility.allowedBundles.isEmpty)
            #expect(fixture.visibility.releases.isEmpty)
        }
    }

    @Test func firstClickAfterAppChangesRescansAndOpensAgain() async throws {
        let fixture = MenuBarToggleFixture()
        defer { fixture.cleanup() }
        fixture.organizer.toggle()
        try await fixture.expectOpened()

        fixture.organizer.appsChanged()
        #expect(fixture.organizer.applications.isEmpty)
        #expect(!fixture.organizer.collapsed)
        #expect(!fixture.tray.isPresented)
        let oldHandle = try #require(fixture.visibility.handles.first)
        #expect(fixture.visibility.releases == [ObjectIdentifier(oldHandle)])

        fixture.organizer.toggle()
        #expect(fixture.organizer.busy)
        try await fixture.expectOpened(activationCount: 2)
        #expect(await fixture.inventory.started == 2)
        #expect(await fixture.entryScan.started == 2)
        #expect(await fixture.capture.started == 2)
        #expect(fixture.organizer.applications.first?.name == "Folded 2")
        #expect(fixture.visibility.releases == [ObjectIdentifier(oldHandle)])
    }
}
