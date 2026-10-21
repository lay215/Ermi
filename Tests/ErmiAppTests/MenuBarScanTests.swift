import AppKit
@preconcurrency import ApplicationServices
import Testing
@testable import Ermi

// 用可控返回顺序模拟无法立即中断的跨进程 AX 调用，验证实际可见数据而非内部版本号。
private actor SuspendedMenuScan {
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<([MenuBarApplication], [Int: Int]), Never>] = [:]
    private var observers: [Int: CheckedContinuation<Void, Never>] = [:]

    func scan() async -> ([MenuBarApplication], [Int: Int]) {
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            observers.removeValue(forKey: id)?.resume()
        }
    }

    func waitForScan(_ id: Int) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { observers[id] = $0 }
    }

    func finish(_ id: Int, named name: String) {
        pending.removeValue(forKey: id)?.resume(returning: ([MenuBarApplication(id: name, name: name, count: 1)], [:]))
    }
}

@MainActor
private final class GroupingVisibilityProbe {
    final class Handle {}
    private(set) var allowedBundles: [Set<String>] = []
    private(set) var handles: [Handle] = []
    private(set) var releases: [ObjectIdentifier] = []

    func access(native: Bool) -> MenuBarVisibilityAccess {
        MenuBarVisibilityAccess(
            native: native, available: { true },
            runningBundleIDs: { ["test.app", "test.other", "test.ermi", "com.apple.controlcenter"] },
            ownBundleID: { "test.ermi" },
            activate: { [self] allowed, completion in
                allowedBundles.append(Set(allowed))
                let handle = Handle()
                handles.append(handle)
                completion(handle, nil)
            },
            release: { [self] handle in
                guard let handle = handle as? Handle else {
                    Issue.record("释放了不属于分组测试的隐藏断言")
                    return
                }
                releases.append(ObjectIdentifier(handle))
            }
        )
    }
}

@MainActor
private final class MenuGroupingFixture {
    let suite = "Ermi.MenuBarGroupingTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let visibility = GroupingVisibilityProbe()
    let tray: MenuBarTray
    let entries: [MenuBarTrayEntry]
    let organizer: MenuBarOrganizer

    init(
        native: Bool = true, folded: [String]? = nil, hidden: [String]? = nil,
        permissionCheck: @escaping () -> Bool = { true }
    ) {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "icons.enabled")
        if let folded { preferences.set(folded, forKey: "icons.folded") }
        if let hidden { preferences.set(hidden, forKey: "icons.hidden") }
        // 入口、权限、点击及截图全部注入；真实 Organizer 仍负责分组过滤和隐藏断言。
        entries = ["test.app", "test.app", "test.other", "test.ermi", "com.apple.controlcenter"].enumerated().map {
            MenuBarTrayEntry(pid: -1, bundleID: $0.element, name: $0.element, label: "Entry \($0.offset)",
                             element: AXUIElementCreateApplication(-1), action: kAXPressAction,
                             frame: CGRect(x: CGFloat(20 + $0.offset * 24), y: 0, width: 20, height: 24))
        }
        let entries = self.entries
        tray = MenuBarTray(
            permissionCheck: permissionCheck,
            permissionRequest: { Issue.record("改组测试不应请求系统授权"); return false },
            identityCheck: { _, _ in true }, scanOverride: { (entries, [:]) },
            actionOverride: { _, _ in Issue.record("改组不能触发菜单点击"); return AXError.failure.rawValue },
            screenCapturePermissionCheck: { true },
            screenCapturePermissionRequest: { Issue.record("改组测试不应请求录屏授权"); return false },
            iconCaptureOverride: { _ in [:] }
        )
        organizer = MenuBarOrganizer(
            defaults: preferences, permissionCheck: permissionCheck,
            scanOverride: {
                // 即使扫描替身带入保护项，公开编辑入口也必须拒绝移动系统和自身。
                ([MenuBarApplication(id: "test.app", name: "App", count: 2),
                  MenuBarApplication(id: "test.other", name: "Other", count: 1),
                  MenuBarApplication(id: "test.ermi", name: "Ermi", count: 1),
                  MenuBarApplication(id: "com.apple.controlcenter", name: "Control Center", count: 1)], [:])
            },
            tray: tray, visibility: visibility.access(native: native)
        )
    }

    func waitUntilSettled() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while organizer.busy && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!organizer.busy)
    }

    func cleanup() {
        organizer.stop()
        preferences.removePersistentDomain(forName: suite)
    }
}

@MainActor
struct MenuBarScanTests {
    private func defaults() -> UserDefaults {
        // 独立 suite 不读取用户分组，也不会启用真实菜单栏状态项。
        UserDefaults(suiteName: "Ermi.MenuBarScanTests.\(UUID().uuidString)")!
    }

    @Test func disablingRejectsLateScan() async {
        let scan = SuspendedMenuScan()
        let preferences = defaults()
        preferences.set(true, forKey: "icons.enabled")
        let organizer = MenuBarOrganizer(defaults: preferences, permissionCheck: { true }, scanOverride: { await scan.scan() })
        let refresh = Task { await organizer.refresh() }
        await scan.waitForScan(0)
        organizer.setEnabled(false)
        await scan.finish(0, named: "Late")
        await refresh.value
        #expect(organizer.applications.isEmpty)
        #expect(!organizer.refreshing)
        #expect(!organizer.enabled)
        preferences.removeObject(forKey: "icons.enabled")
    }

    @Test func newerScanWinsEvenWhenOlderReturnsLast() async {
        let scan = SuspendedMenuScan()
        let organizer = MenuBarOrganizer(defaults: defaults(), permissionCheck: { true }, scanOverride: { await scan.scan() })
        let first = Task { await organizer.refresh() }
        await scan.waitForScan(0)
        let second = Task { await organizer.refresh() }
        await scan.waitForScan(1)
        await scan.finish(1, named: "Current")
        await second.value
        #expect(organizer.applications.map(\.id) == ["Current"])
        await scan.finish(0, named: "Stale")
        await first.value
        #expect(organizer.applications.map(\.id) == ["Current"])
        #expect(!organizer.refreshing)
    }

    @Test func permissionRevocationRejectsInFlightResult() async {
        let scan = SuspendedMenuScan()
        var authorized = true
        let organizer = MenuBarOrganizer(defaults: defaults(), permissionCheck: { authorized }, scanOverride: { await scan.scan() })
        let refresh = Task { await organizer.refresh() }
        await scan.waitForScan(0)
        authorized = false
        await scan.finish(0, named: "NoLongerAuthorized")
        await refresh.value
        #expect(!organizer.authorized)
        #expect(organizer.applications.isEmpty)
        #expect(!organizer.refreshing)
    }
    @Test func immediatePermissionGrantStillRefreshesEntries() async {
        var granted = false
        let organizer = MenuBarOrganizer(
            defaults: defaults(), permissionCheck: { granted },
            permissionRequest: { granted = true; return true },
            scanOverride: { ([MenuBarApplication(id: "Granted", name: "Granted", count: 1)], [:]) }
        )
        organizer.requestPermission()
        #expect(organizer.authorized)
        await organizer.synchronizePermission()
        #expect(organizer.applications.map(\.id) == ["Granted"])
    }

    @Test func appChangesRefreshWithoutPermissionChange() async {
        let scan = SuspendedMenuScan()
        let organizer = MenuBarOrganizer(defaults: defaults(), permissionCheck: { true }, scanOverride: { await scan.scan() })
        let first = Task { await organizer.refresh() }
        await scan.waitForScan(0)
        await scan.finish(0, named: "Before")
        await first.value
        organizer.appsChanged()
        let update = Task { await organizer.synchronizePermission() }
        await scan.waitForScan(1)
        await scan.finish(1, named: "After")
        await update.value
        #expect(organizer.applications.map(\.id) == ["After"])
    }

    @Test func unauthorizedRefreshRequestsPermissionThenRefreshesOnReturn() async {
        var granted = false
        var prompts = 0
        let organizer = MenuBarOrganizer(
            defaults: defaults(), permissionCheck: { granted },
            permissionRequest: { prompts += 1; return granted },
            scanOverride: { ([MenuBarApplication(id: "Allowed", name: "Allowed", count: 1)], [:]) }
        )
        await organizer.refreshFromUser()
        #expect(prompts == 1)
        #expect(organizer.applications.isEmpty)
        granted = true
        await organizer.synchronizePermission()
        #expect(organizer.applications.map(\.id) == ["Allowed"])
        #expect(prompts == 1)
    }

    @Test func movingBetweenGroupsPersistsTheAppAndAllItsEntries() async {
        let fixture = MenuGroupingFixture(folded: ["test.other"])
        defer { fixture.cleanup() }
        let organizer = fixture.organizer
        await organizer.refresh()
        #expect(organizer.setFolded("test.app", true))
        await fixture.waitUntilSettled()
        #expect(organizer.folded == ["test.app", "test.other"])
        #expect(organizer.applications.first(where: { $0.id == "test.app" })?.count == 2)
        #expect(organizer.collapsed)
        #expect(MenuBarOrganizer(defaults: fixture.preferences, permissionCheck: { true }).folded == organizer.folded)
        #expect(organizer.setFolded("test.app", false))
        await fixture.waitUntilSettled()
        #expect(organizer.folded == ["test.other"])
        #expect(organizer.collapsed)
        #expect(fixture.visibility.allowedBundles.last?.contains("test.app") == true)
        #expect(!organizer.setFolded("test.app", false))
    }

    @Test func groupMovesRejectUnknownDisabledAndRevokedEntries() async {
        let preferences = defaults()
        preferences.set(true, forKey: "icons.enabled")
        var granted = true
        let organizer = MenuBarOrganizer(defaults: preferences, permissionCheck: { granted }, scanOverride: {
            ([MenuBarApplication(id: "test.app", name: "App", count: 1)], [:])
        })
        await organizer.refresh()
        // 外部拖入的文本不能创建分组记录；撤权和停用也不能用之前缓存的 App 修改偏好。
        #expect(!organizer.setFolded("unknown.bundle", true))
        granted = false
        #expect(!organizer.setFolded("test.app", true))
        granted = true
        organizer.setEnabled(false)
        #expect(!organizer.setFolded("test.app", true))
        #expect(organizer.folded.isEmpty)
        #expect(preferences.stringArray(forKey: "icons.folded") == nil)
    }

    @Test func scanInProgressRejectsGroupMovesUntilInventoryIsCurrent() async {
        let preferences = defaults()
        preferences.set(true, forKey: "icons.enabled")
        let scan = SuspendedMenuScan()
        let visibility = GroupingVisibilityProbe()
        let tray = MenuBarTray(permissionCheck: { true }, permissionRequest: { false }, identityCheck: { _, _ in true },
                               scanOverride: { ([], [:]) }, actionOverride: { _, _ in AXError.failure.rawValue },
                               screenCapturePermissionCheck: { false }, screenCapturePermissionRequest: { false },
                               iconCaptureOverride: { _ in [:] })
        let organizer = MenuBarOrganizer(defaults: preferences, permissionCheck: { true }, scanOverride: { await scan.scan() },
                                         tray: tray, visibility: visibility.access(native: true))
        defer { organizer.stop() }
        let first = Task { await organizer.refresh() }
        await scan.waitForScan(0)
        await scan.finish(0, named: "App")
        await first.value
        let second = Task { await organizer.refresh() }
        await scan.waitForScan(1)
        #expect(!organizer.setFolded("App", true))
        await scan.finish(1, named: "App")
        await second.value
        #expect(organizer.setFolded("App", true))
    }

    @Test func everyThreeGroupTransitionMovesTheWholeAppAndPersists() async {
        let fixture = MenuGroupingFixture(folded: ["test.other"])
        defer { fixture.cleanup() }
        let organizer = fixture.organizer
        await organizer.refresh()

        // 这条路径覆盖三组之间全部六种方向；两个入口始终随同一个 App 一起归组。
        let destinations: [MenuBarIconGroup] = [.folded, .hidden, .retained, .hidden, .folded, .retained]
        for destination in destinations {
            #expect(organizer.setGroup("test.app", destination))
            await fixture.waitUntilSettled()
            #expect(organizer.group(for: "test.app") == destination)
            #expect(organizer.folded.contains("test.app") == (destination == .folded))
            #expect(organizer.hidden.contains("test.app") == (destination == .hidden))
            #expect(organizer.folded.isDisjoint(with: organizer.hidden))
            #expect(organizer.group(for: "test.other") == .folded)
            #expect(organizer.applications.first(where: { $0.id == "test.app" })?.count == 2)
            #expect(organizer.collapsed)
            // 收起和隐藏都离开顶部，只有收起的两个入口可以进入展开栏；保留项立即回到白名单。
            let allowed = fixture.visibility.allowedBundles.last ?? []
            #expect(allowed.contains("test.app") == (destination == .retained))
            #expect(!allowed.contains("test.other"))
            #expect(allowed.isSuperset(of: ["test.ermi", "com.apple.controlcenter"]))
            #expect(fixture.tray.entries.filter { $0.bundleID == "test.app" }.map(\.id) ==
                    (destination == .folded ? Array(fixture.entries.prefix(2)).map(\.id) : []))
            #expect(fixture.tray.entries.filter { $0.bundleID == "test.other" }.count == 1)
            #expect(!fixture.tray.isPresented)
            #expect(!organizer.setGroup("test.app", destination))
            let reloaded = MenuBarOrganizer(defaults: fixture.preferences, permissionCheck: { true })
            #expect(reloaded.group(for: "test.app") == destination)
            #expect(reloaded.folded == organizer.folded)
            #expect(reloaded.hidden == organizer.hidden)
        }
        #expect(fixture.visibility.allowedBundles.count == destinations.count)
        #expect(fixture.visibility.releases == fixture.visibility.handles.dropLast().map(ObjectIdentifier.init))
    }

    @Test func missingHiddenPreferencePreservesExistingFoldedConfiguration() async {
        let fixture = MenuGroupingFixture(folded: ["test.app"])
        defer { fixture.cleanup() }
        let organizer = fixture.organizer
        #expect(organizer.folded == ["test.app"])
        #expect(organizer.hidden.isEmpty)
        #expect(organizer.group(for: "test.app") == .folded)
        #expect(organizer.group(for: "test.other") == .retained)
        #expect(fixture.preferences.object(forKey: "icons.hidden") == nil)

        await organizer.refresh()
        #expect(organizer.setFolded("test.app", false))
        await fixture.waitUntilSettled()
        #expect(organizer.group(for: "test.app") == .retained)
        #expect(!organizer.collapsed)
        #expect(organizer.setFolded("test.app", true))
        await fixture.waitUntilSettled()
        #expect(organizer.group(for: "test.app") == .folded)
        #expect(organizer.hidden.isEmpty)
    }

    @Test func conflictingPreferencesGiveHiddenPriorityUntilExplicitlyMoved() async {
        let fixture = MenuGroupingFixture(folded: ["test.app", "test.other"], hidden: ["test.app"])
        defer { fixture.cleanup() }
        let organizer = fixture.organizer
        #expect(organizer.group(for: "test.app") == .hidden)
        #expect(organizer.folded == ["test.other"])
        #expect(organizer.hidden == ["test.app"])
        await organizer.refresh()
        #expect(organizer.setFolded("test.app", true))
        await fixture.waitUntilSettled()
        #expect(organizer.hidden.isEmpty)
        #expect(Set(fixture.preferences.stringArray(forKey: "icons.folded") ?? []) == ["test.app", "test.other"])
        #expect((fixture.preferences.stringArray(forKey: "icons.hidden") ?? []).isEmpty)
        let reloaded = MenuBarOrganizer(defaults: fixture.preferences, permissionCheck: { true })
        #expect(reloaded.group(for: "test.app") == .folded)
        #expect(reloaded.folded.isDisjoint(with: reloaded.hidden))
        #expect(organizer.setGroup("test.app", .hidden))
        await fixture.waitUntilSettled()
        #expect(organizer.setFolded("test.app", false))
        await fixture.waitUntilSettled()
        #expect(organizer.group(for: "test.app") == .retained)
        #expect(!organizer.folded.contains("test.app"))
        #expect(!organizer.hidden.contains("test.app"))
    }

    @Test func groupMovesRejectSystemSelfAndUnknownAppsEvenWithInjectedInventory() async {
        let fixture = MenuGroupingFixture()
        defer { fixture.cleanup() }
        await fixture.organizer.refresh()
        for id in ["com.apple.controlcenter", "test.ermi", "unknown.bundle"] {
            #expect(!fixture.organizer.setGroup(id, .folded))
            #expect(!fixture.organizer.setGroup(id, .hidden))
        }
        #expect(fixture.organizer.folded.isEmpty)
        #expect(fixture.organizer.hidden.isEmpty)
    }

    @Test func legacySystemsRejectHiddenGroupWithoutChangingExistingFoldedPreferences() async {
        let fixture = MenuGroupingFixture(native: false, folded: ["test.app"])
        defer { fixture.cleanup() }
        await fixture.organizer.refresh()
        #expect(!fixture.organizer.setGroup("test.app", .hidden))
        #expect(!fixture.organizer.setGroup("test.other", .hidden))
        #expect(fixture.organizer.group(for: "test.app") == .folded)
        #expect(fixture.organizer.hidden.isEmpty)
        #expect(fixture.preferences.stringArray(forKey: "icons.folded") == ["test.app"])
        #expect(fixture.preferences.object(forKey: "icons.hidden") == nil)
    }

    @Test func hiddenMovesCannotBypassPermissionRevocationOrDisable() async {
        var granted = true
        let fixture = MenuGroupingFixture(permissionCheck: { granted })
        defer { fixture.cleanup() }
        await fixture.organizer.refresh()
        granted = false
        #expect(!fixture.organizer.setGroup("test.app", .hidden))
        granted = true
        fixture.organizer.setEnabled(false)
        #expect(!fixture.organizer.setGroup("test.app", .hidden))
        #expect(fixture.organizer.hidden.isEmpty)
        #expect(fixture.preferences.object(forKey: "icons.hidden") == nil)
    }

}
