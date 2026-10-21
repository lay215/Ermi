import AppKit
@preconcurrency import ApplicationServices
import Testing
@testable import Ermi

private actor OrderingInventory {
    var omitted: Set<String> = []
    var protectedEntries = false
    func omit(_ ids: Set<String>) { omitted = ids }
    func includeProtectedEntries() { protectedEntries = true }
    func scan() -> ([MenuBarApplication], [Int: Int]) {
        var names = [("test.c", "Charlie"), ("test.a", "Alpha"), ("test.r", "Retained"),
                     ("test.b", "Beta"), ("test.h", "Hidden")]
        if protectedEntries { names += [("test.ermi", "Ermi"), ("com.apple.controlcenter", "Control Center")] }
        return (names.filter { !omitted.contains($0.0) }.map {
            MenuBarApplication(id: $0.0, name: $0.1, count: $0.0 == "test.a" ? 2 : 1)
        }, [:])
    }
}

private actor EntryOrderingInventory {
    var entries: [MenuBarTrayEntry]
    init(_ entries: [MenuBarTrayEntry]) { self.entries = entries }
    func reverse() { entries.reverse() }
    func remove(_ id: String) { entries.removeAll { $0.orderingID == id } }
    func scan() -> ([MenuBarApplication], [Int: Int]) {
        // 同 bundle 的多个记录模拟多进程 App；扫描合并后仍必须保留两个精确入口。
        (entries.map { .init(id: $0.bundleID, name: $0.name, count: 1, entryIDs: [$0.orderingID]) }, [:])
    }
}

@MainActor
private final class OrderingProbe {
    final class Handle {}
    var activations = 0
    var releases = 0
    var orders: [[String]] = []
    var actions: [(UUID, String, AXUIElement)] = []
    var result: MenuBarOrderResult = .success(moved: 2)
    var hold = false
    var pending: CheckedContinuation<MenuBarOrderResult, Never>?

    var visibility: MenuBarVisibilityAccess {
        MenuBarVisibilityAccess(
            native: true, available: { true },
            runningBundleIDs: { ["test.a", "test.b", "test.c", "test.h", "test.r", "test.ermi"] },
            ownBundleID: { "test.ermi" },
            activate: { [self] _, completion in activations += 1; completion(Handle(), nil) },
            release: { [self] _ in releases += 1 }
        )
    }

    var access: MenuBarOrderAccess {
        MenuBarOrderAccess(apply: { [self] order in
            orders.append(order)
            if hold { return await withCheckedContinuation { pending = $0 } }
            return result
        })
    }

    func finish() {
        pending?.resume(returning: result)
        pending = nil
    }
}

@MainActor
private func orderingEventually(_ predicate: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

@MainActor
private final class OrderingFixture {
    let suite = "Ermi.MenuBarOrderingTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let inventory = OrderingInventory()
    let probe = OrderingProbe()
    let original: [MenuBarTrayEntry]
    let tray: MenuBarTray
    let organizer: MenuBarOrganizer

    init(order: [String]? = nil) {
        _ = NSApplication.shared
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "icons.enabled")
        defaults.set(["test.a", "test.b", "test.c"], forKey: "icons.folded")
        defaults.set(["test.h"], forKey: "icons.hidden")
        if let order { defaults.set(order, forKey: "icons.order") }
        // 无效 PID 仅提供 AX 类型；所有扫描、系统排序、隐藏和点击均替身注入。
        original = [("test.b", CGFloat(10), kAXPressAction),
                    ("test.a", CGFloat(20), kAXPressAction),
                    ("test.a", CGFloat(30), kAXShowMenuAction),
                    ("test.c", CGFloat(40), kAXPressAction)].map { bundle, x, action in
            MenuBarTrayEntry(pid: -1, bundleID: bundle, name: bundle, label: "\(bundle)-\(x)",
                            element: AXUIElementCreateApplication(-1), action: action,
                            frame: CGRect(x: x, y: 0, width: 20, height: 24))
        }
        let entries = original
        let probe = self.probe
        let inventory = self.inventory
        tray = MenuBarTray(
            permissionCheck: { true }, permissionRequest: { false }, identityCheck: { _, _ in true },
            scanOverride: { (Array(entries.reversed()), [:]) },
            actionOverride: { entry, action in
                await MainActor.run { probe.actions.append((entry.id, action, entry.element)) }
                return AXError.success.rawValue
            },
            screenCapturePermissionCheck: { false }, screenCapturePermissionRequest: { false }
        )
        organizer = MenuBarOrganizer(
            defaults: defaults, permissionCheck: { true }, permissionRequest: { false },
            scanOverride: { await inventory.scan() }, tray: tray,
            visibility: probe.visibility, orderAccess: probe.access
        )
    }

    func collapse(show: Bool = false) async throws {
        await organizer.refresh()
        organizer.collapse(openingTray: show)
        try #require(await orderingEventually { !self.organizer.busy })
        try #require(organizer.collapsed)
        #expect(tray.isPresented == show)
    }

    func cleanup() {
        organizer.stop()
        probe.finish()
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite(.serialized)
@MainActor
struct MenuBarOrderingTests {
    @Test func openVPNThemeObserverDoesNotDuplicateIconOrBlockGroupDrag() async throws {
        _ = NSApplication.shared
        let bundle = "org.openvpn.client.app"
        let suite = "Ermi.OpenVPNEntryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "icons.enabled")
        // 回放实测的 19×24 图标和 2×24 主题观察状态项；AX 引用保持独立，不能按 bundle 去重。
        let raw = [AXUIElementCreateApplication(-951), AXUIElementCreateApplication(-952)]
        let selected = MenuBarEntryFilter.managedItems(raw, bundleID: bundle) {
            CGSize(width: CFEqual($0, raw[0]) ? 19 : 2, height: 24)
        }
        let entries = selected.map {
            MenuBarTrayEntry(pid: -951, bundleID: bundle, name: "OpenVPN Connect", label: "菜单栏入口",
                             element: $0, action: kAXPressAction)
        }
        let identities = entries.map(\.orderingID)
        let inventory = MenuBarApplication(id: bundle, name: "OpenVPN Connect", count: entries.count, entryIDs: identities)
        var allowedBundles: [Set<String>] = []
        let tray = MenuBarTray(permissionCheck: { true }, identityCheck: { _, _ in true },
            scanOverride: { (entries, [:]) }, screenCapturePermissionCheck: { false })
        let organizer = MenuBarOrganizer(defaults: defaults, permissionCheck: { true },
            scanOverride: { ([inventory], [:]) }, tray: tray,
            visibility: MenuBarVisibilityAccess(native: true, available: { true },
                runningBundleIDs: { [bundle, "test.other", "test.ermi"] }, ownBundleID: { "test.ermi" },
                activate: { allowed, completion in
                    allowedBundles.append(Set(allowed))
                    completion(OrderingProbe.Handle(), nil)
                }, release: { _ in }))
        defer { organizer.stop(); defaults.removePersistentDomain(forName: suite) }
        await organizer.refresh()
        #expect(organizer.orderedIcons.count == 1)
        #expect(organizer.orderedIcons.map(\.name) == ["OpenVPN Connect"])
        let id = try #require(identities.first)
        #expect(organizer.moveEntry(id, to: .folded))
        try #require(await orderingEventually { !organizer.busy })
        #expect(organizer.group(for: bundle) == .folded)
        #expect(organizer.collapsed)
        #expect(tray.entries.count == 1)
        #expect(tray.entries.first.map { CFEqual($0.element, raw[0]) } == true)
        #expect(allowedBundles.last?.contains(bundle) == false)
        #expect(allowedBundles.last?.contains("test.other") == true)
        #expect(organizer.moveEntry(id, to: .hidden))
        try #require(await orderingEventually { !organizer.busy })
        #expect(organizer.group(for: bundle) == .hidden)
        #expect(tray.entries.isEmpty)
        #expect(organizer.moveEntry(id, to: .retained))
        try #require(await orderingEventually { !organizer.busy })
        #expect(organizer.group(for: bundle) == .retained)
        #expect(!organizer.collapsed)
    }

    @Test func entryFilterPreservesRealMultipleIconsAndUnknownSizes() {
        let raw = [AXUIElementCreateApplication(-961), AXUIElementCreateApplication(-962)]
        // 规则只针对已核实的 OpenVPN 空状态项：其他 App 的窄图标，以及无法读取的入口都保留。
        #expect(MenuBarEntryFilter.managedItems(raw, bundleID: "test.other") { _ in CGSize(width: 2, height: 24) }.count == 2)
        for size: CGSize? in [nil, CGSize(width: CGFloat.nan, height: 24), CGSize(width: -1, height: 24),
                             CGSize(width: 2, height: 0), CGSize(width: 19, height: 24)] {
            #expect(MenuBarEntryFilter.managedItems(raw, bundleID: "org.openvpn.client.app") { _ in size }.count == 2)
        }
        for width: CGFloat in [0, 1, 2] {
            #expect(MenuBarEntryFilter.managedItems(raw, bundleID: "org.openvpn.client.app") {
                _ in CGSize(width: width, height: 24)
            }.isEmpty)
        }
    }

    @Test func entryIdentityUsesExactElementAndOwnerInsteadOfScanIndex() {
        let registry = MenuBarEntryIdentity()
        let first = AXUIElementCreateApplication(-901)
        let second = AXUIElementCreateApplication(-902)
        let a = registry.id(pid: -901, bundleID: "test.vpn", element: first)
        let b = registry.id(pid: -901, bundleID: "test.vpn", element: second)
        #expect(a != b)
        // 顺序、名称和位置都不参与身份；新 AX 包装引用若 CFEqual 相等，仍识别为原入口。
        #expect(registry.id(pid: -901, bundleID: "test.vpn", element: AXUIElementCreateApplication(-901)) == a)
        #expect(registry.id(pid: -902, bundleID: "test.vpn", element: first) != a)
        #expect(registry.id(pid: -901, bundleID: "other.app", element: first) != a)
        #expect(registry.bundleID(for: a) == "test.vpn")
        #expect(registry.bundleID(for: "entry:unknown") == nil)
    }

    @Test func nativePlanSeparatesSameAppEntriesAndRejectsRebuiltOrMissingEntries() throws {
        let positions = [
            MenuBarOrderPlan.Position(id: 1, bundleID: "vpn", displayID: 1, frame: CGRect(x: 10, y: 0, width: 20, height: 24), entryID: "entry:a"),
            MenuBarOrderPlan.Position(id: 2, bundleID: "other", displayID: 1, frame: CGRect(x: 40, y: 0, width: 20, height: 24), entryID: "entry:b"),
            MenuBarOrderPlan.Position(id: 3, bundleID: "vpn", displayID: 1, frame: CGRect(x: 70, y: 0, width: 20, height: 24), entryID: "entry:c")
        ]
        let plan = try #require(MenuBarOrderPlan(positions: positions, entryIDs: ["entry:a", "entry:c", "entry:b"]))
        #expect(plan.nextMove(in: positions) == .init(source: 3, before: 2))
        #expect(plan.targetByDisplay == [1: [1, 3, 2]])
        #expect(MenuBarOrderPlan(positions: positions, entryIDs: ["entry:a", "entry:b"]) == nil)
        #expect(MenuBarOrderPlan(positions: positions, entryIDs: ["entry:a", "entry:b", "entry:new"]) == nil)
        #expect(MenuBarOrderPlan(positions: positions, entryIDs: ["entry:a", "entry:a", "entry:c"]) == nil)
    }

    @Test func individualDragFlowsThroughSettingsTrayRefreshAndNativeSync() async throws {
        _ = NSApplication.shared
        let suite = "Ermi.EntryOrderingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "icons.enabled")
        defaults.set(["test.a", "test.b"], forKey: "icons.folded")
        let probe = OrderingProbe()
        // 入口来自不同的替身 AX 元素，任何系统点击和系统排序均替身注入。
        let original = [("test.a", pid_t(-801), kAXPressAction), ("test.b", pid_t(-802), kAXPressAction),
                        ("test.a", pid_t(-803), kAXShowMenuAction)].enumerated().map { index, value in
            MenuBarTrayEntry(pid: value.1, bundleID: value.0, name: value.0, label: "entry \(index)",
                            element: AXUIElementCreateApplication(value.1), action: value.2,
                            frame: CGRect(x: index * 30, y: 0, width: 20, height: 24))
        }
        let a1 = original[0].orderingID, b = original[1].orderingID, a2 = original[2].orderingID
        let inventory = EntryOrderingInventory(original)
        let tray = MenuBarTray(permissionCheck: { true }, permissionRequest: { false }, identityCheck: { _, _ in true },
            scanOverride: { (original, [:]) }, actionOverride: { entry, action in
                await MainActor.run { probe.actions.append((entry.id, action, entry.element)) }
                return AXError.success.rawValue
            }, screenCapturePermissionCheck: { false }, screenCapturePermissionRequest: { false })
        let organizer = MenuBarOrganizer(defaults: defaults, permissionCheck: { true }, permissionRequest: { false },
            scanOverride: { await inventory.scan() }, tray: tray, visibility: probe.visibility, orderAccess: probe.access)
        defer { organizer.stop(); defaults.removePersistentDomain(forName: suite) }
        await organizer.refresh()
        #expect(organizer.applications.first { $0.id == "test.a" }?.count == 2)
        organizer.collapse(openingTray: true)
        try #require(await orderingEventually { !organizer.busy && tray.isPresented })
        // 先拉开同 App 两个入口，再只移动第二个；另一入口的相对顺序不能跟着成组移动。
        #expect(organizer.moveEntry(a2, to: .folded))
        #expect(organizer.orderedIcons.map(\.id) == [a1, b, a2])
        #expect(organizer.moveEntry(a2, to: .folded, before: b))
        #expect(tray.entries.map(\.orderingID) == [a1, a2, b])
        #expect(tray.moveEntry(a1, before: nil))
        #expect(organizer.orderedIcons.map(\.id) == [a2, b, a1])
        #expect(tray.entries.map(\.orderingID) == [a2, b, a1])
        #expect(organizer.collapsed && probe.releases == 0)
        let selected = try #require(tray.entries.first { $0.orderingID == a2 })
        await tray.activate(selected)
        #expect(probe.actions.first?.0 == original[2].id)
        #expect(probe.actions.first?.1 == kAXShowMenuAction)
        #expect(CFEqual(try #require(probe.actions.first?.2), original[2].element))
        // 清单返回次序变化不能改掉排序，也不能偷偷把另一个入口一起移到隐藏组。
        await inventory.reverse()
        await organizer.refresh()
        #expect(organizer.orderedIcons.map(\.id) == [a2, b, a1])
        #expect(organizer.orderedIcons.first { $0.id == a1 }?.name == "test.a 1")
        #expect(organizer.orderedIcons.first { $0.id == a2 }?.name == "test.a 2")
        #expect(!organizer.moveEntry(a1, to: .hidden))
        #expect(organizer.group(for: "test.a") == .folded)
        #expect(!organizer.moveEntry("entry:unknown", to: .folded))
        #expect(organizer.shiftEntry(a1, by: -1))
        #expect(organizer.orderedIcons.map(\.id) == [a2, a1, b])
        organizer.applyMenuBarOrder()
        try #require(await orderingEventually { !organizer.sorting })
        #expect(probe.orders == [[a2, a1, b]])
        await inventory.remove(a1)
        await organizer.refresh()
        #expect(!organizer.moveEntry(a1, to: .folded))
        #expect(!organizer.moveEntry(a2, to: .folded, before: a1))
        #expect(organizer.orderedIcons.map(\.id) == [a2, b])
        organizer.setEnabled(false)
        #expect(!organizer.moveEntry(a2, to: .folded, before: b))
    }

    @Test func settingsShowMultipleEntriesSeparatelyWithoutChangingAppIdentity() {
        let app = MenuBarApplication(id: "test.vpn", name: "OpenVPN Connect", count: 2)
        let icons = MenuBarApplicationIcon.items(for: app)
        #expect(icons.count == 2)
        #expect(Set(icons.map(\.id)).count == 2)
        #expect(icons.map(\.name) == ["OpenVPN Connect 1", "OpenVPN Connect 2"])
        #expect(icons.allSatisfy { $0.application.id == app.id })
        // 刷新不随机更换卡片身份；单入口无多余序号，也不为零入口合成占位图标。
        #expect(MenuBarApplicationIcon.items(for: app).map(\.id) == icons.map(\.id))
        #expect(MenuBarApplicationIcon.items(for: .init(id: "single", name: "Single", count: 1)).map(\.name) == ["Single"])
        #expect(MenuBarApplicationIcon.items(for: .init(id: "empty", name: "Empty", count: 0)).isEmpty)
    }

    private func position(_ id: Int, _ bundle: String, _ x: CGFloat, display: CGDirectDisplayID = 1) -> MenuBarOrderPlan.Position {
        .init(id: id, bundleID: bundle, displayID: display, frame: CGRect(x: x, y: 0, width: 20, height: 24))
    }

    @Test func nativePlanPreservesSameAppOrderAndAdvancesUsingRereadPositions() throws {
        let original = [position(2, "a", 30), position(4, "c", 40), position(1, "b", 10), position(3, "a", 20)]
        let plan = try #require(MenuBarOrderPlan(positions: original, bundleIDs: ["a", "b", "c"]))
        #expect(plan.targetByDisplay == [1: [3, 2, 1, 4]])
        #expect(!plan.isSatisfied(by: original))
        #expect(plan.nextMove(in: original) == .init(source: 3, before: 1))
        // 每次事件之后以新坐标继续规划；同 App 两个入口的相对顺序来自首次真实位置。
        let afterFirst = [position(2, "a", 30), position(4, "c", 40), position(1, "b", 10), position(3, "a", 5)]
        #expect(plan.nextMove(in: afterFirst) == .init(source: 2, before: 1))
        let completed = [position(2, "a", 7), position(4, "c", 40), position(1, "b", 10), position(3, "a", 5)]
        #expect(plan.isSatisfied(by: completed))
        #expect(plan.nextMove(in: completed) == nil)
    }

    @Test func nativePlanKeepsDisplaysIndependentAndRejectsAnyStaleIdentity() throws {
        let original = [position(1, "b", 10), position(2, "a", 30),
                        position(3, "b", -100, display: 2), position(4, "a", -80, display: 2)]
        let plan = try #require(MenuBarOrderPlan(positions: original, bundleIDs: ["a", "b"]))
        #expect(plan.targetByDisplay == [1: [2, 1], 2: [4, 3]])
        #expect(plan.nextMove(in: original) == .init(source: 2, before: 1))
        let firstDisplayDone = [position(1, "b", 10), position(2, "a", 5),
                                position(3, "b", -100, display: 2), position(4, "a", -80, display: 2)]
        #expect(plan.nextMove(in: firstDisplayDone) == .init(source: 4, before: 3))
        // 后一个显示器缺项也必须停止所有动作，不能先改第一个显示器再发现计划失效。
        let missingSecondDisplayItem = Array(original.dropLast())
        #expect(!plan.isSatisfied(by: missingSecondDisplayItem))
        #expect(plan.nextMove(in: missingSecondDisplayItem) == nil)
        let replaced = Array(original.dropLast()) + [position(9, "a", -80, display: 2)]
        #expect(!plan.isSatisfied(by: replaced))
        #expect(plan.nextMove(in: replaced) == nil)
        let movedDisplay = Array(original.dropLast()) + [position(4, "a", 50)]
        #expect(plan.nextMove(in: movedDisplay) == nil)
    }

    @Test func nativePlanRejectsAmbiguousIDsAndUnrequestedApps() {
        #expect(MenuBarOrderPlan(positions: [position(1, "a", 10), position(1, "b", 30)], bundleIDs: ["a", "b"]) == nil)
        #expect(MenuBarOrderPlan(positions: [position(1, "unknown", 10)], bundleIDs: ["a", "b"]) == nil)
        let empty = MenuBarOrderPlan(positions: [], bundleIDs: ["a"])
        #expect(empty?.isSatisfied(by: []) == true)
        #expect(empty?.nextMove(in: []) == nil)
    }

    @Test func missingPreferenceKeepsSettingsNameOrderAndTrayPositionOrder() async throws {
        let fixture = OrderingFixture()
        defer { fixture.cleanup() }
        try await fixture.collapse()
        #expect(fixture.organizer.applicationOrder.isEmpty)
        #expect(fixture.organizer.orderedApplications.map(\.id) == ["test.a", "test.b", "test.c", "test.h", "test.r"])
        #expect(fixture.tray.entries.map(\.id) == fixture.original.map(\.id))
        #expect(fixture.defaults.object(forKey: "icons.order") == nil)
        fixture.organizer.applyMenuBarOrder()
        #expect(fixture.probe.orders.isEmpty)
        #expect(fixture.probe.releases == 0)
    }

    @Test func savedOrderSurvivesRefreshExitAndReturnWithoutDroppingUnknownIDs() async {
        let fixture = OrderingFixture(order: ["test.c", "", "test.a", "test.c", "test.future", "test.b"])
        defer { fixture.cleanup() }
        await fixture.organizer.refresh()
        #expect(fixture.organizer.applicationOrder == ["test.c", "test.a", "test.future", "test.b"])
        #expect(fixture.organizer.orderedApplications.map(\.id) == ["test.c", "test.a", "test.b", "test.h", "test.r"])
        #expect(fixture.organizer.moveApplication("test.b", to: .folded, before: "test.c"))
        let saved = fixture.organizer.applicationOrder
        #expect(saved.contains("test.future"))
        #expect(fixture.defaults.stringArray(forKey: "icons.order") == saved)
        await fixture.inventory.omit(["test.b"])
        fixture.organizer.appsChanged()
        await fixture.organizer.refresh()
        #expect(fixture.organizer.applicationOrder == saved)
        #expect(!fixture.organizer.orderedApplications.contains { $0.id == "test.b" })
        await fixture.inventory.omit([])
        await fixture.organizer.refresh()
        #expect(fixture.organizer.orderedApplications.first?.id == "test.b")
        #expect(fixture.organizer.applicationOrder == saved)

        // 新实例读取同一偏好，验证顺序不是仅保留在当前 Observable 实例中。
        let restored = MenuBarOrganizer(defaults: fixture.defaults, permissionCheck: { true },
                                        visibility: fixture.probe.visibility, orderAccess: fixture.probe.access)
        #expect(restored.applicationOrder == saved)
        restored.stop()
    }

    @Test func localReorderingKeepsHiddenAssertionAndExactMultiEntryActions() async throws {
        let fixture = OrderingFixture()
        defer { fixture.cleanup() }
        try await fixture.collapse(show: true)
        let originals = fixture.tray.entries
        // 经过展开栏真实拖放回调，验证与设置共用的排序偏好和原 AX 动作身份。
        #expect(fixture.tray.moveApplication("test.c", before: "test.a"))
        #expect(fixture.organizer.applicationOrder.first == "test.c")
        #expect(fixture.tray.entries.map(\.id) == [
            fixture.original[3].id, fixture.original[1].id, fixture.original[2].id, fixture.original[0].id
        ])
        #expect(fixture.organizer.collapsed)
        #expect(fixture.probe.releases == 0)
        #expect(fixture.probe.orders.isEmpty)
        for entry in fixture.tray.entries {
            let original = try #require(originals.first { $0.id == entry.id })
            #expect(CFEqual(entry.element, original.element))
            #expect(entry.action == original.action)
            #expect(entry.icon === original.icon)
            #expect(entry.fallbackIcon === original.fallbackIcon)
        }
        let selected = try #require(fixture.tray.entries.first { $0.id == fixture.original[2].id })
        await fixture.tray.activate(selected)
        #expect(fixture.probe.actions.count == 1)
        #expect(fixture.probe.actions.first?.0 == fixture.original[2].id)
        #expect(fixture.probe.actions.first?.1 == kAXShowMenuAction)
        #expect(CFEqual(try #require(fixture.probe.actions.first?.2), fixture.original[2].element))
        #expect(fixture.organizer.collapsed)
        #expect(fixture.probe.releases == 0)
        fixture.tray.setApplicationOrder([])
        #expect(fixture.tray.entries.map(\.id) == fixture.original.map(\.id))
    }

    @Test func identityBasedMovesHandleHiddenSearchNeighborsAndRejectInvalidRequests() async throws {
        let fixture = OrderingFixture()
        defer { fixture.cleanup() }
        try await fixture.collapse()
        // 即使搜索只显示 a 和 c，before 使用完整分组的身份，不把 b 当作目标下标。
        #expect(fixture.organizer.moveApplication("test.c", to: .folded, before: "test.a"))
        #expect(fixture.organizer.orderedApplications.filter { fixture.organizer.group(for: $0.id) == .folded }.map(\.id)
                == ["test.c", "test.a", "test.b"])
        let saved = fixture.organizer.applicationOrder
        #expect(!fixture.organizer.moveApplication("test.c", to: .folded, before: "test.a"))
        #expect(!fixture.organizer.moveApplication("test.c", to: .folded, before: "test.c"))
        #expect(!fixture.organizer.moveApplication("test.unknown", to: .folded))
        #expect(!fixture.organizer.moveApplication("test.ermi", to: .folded))
        #expect(!fixture.organizer.moveApplication("com.apple.controlcenter", to: .folded))
        #expect(!fixture.organizer.moveApplication("test.c", to: .folded, before: "test.h"))
        #expect(!fixture.organizer.moveApplication("test.c", to: .folded, before: "test.unknown"))
        #expect(!fixture.organizer.canShiftApplication("test.c", by: -1))
        #expect(!fixture.organizer.shiftApplication("test.b", by: 1))
        #expect(!fixture.organizer.shiftApplication("test.a", by: 2))
        #expect(fixture.organizer.applicationOrder == saved)
        #expect(fixture.organizer.shiftApplication("test.a", by: -1))
        #expect(fixture.organizer.orderedApplications.first?.id == "test.a")
        #expect(fixture.organizer.shiftApplication("test.a", by: 1))
        #expect(fixture.organizer.orderedApplications.filter { fixture.organizer.group(for: $0.id) == .folded }.map(\.id)
                == ["test.c", "test.a", "test.b"])
        #expect(fixture.probe.releases == 0)
        #expect(fixture.organizer.moveApplication("test.b", to: .hidden, before: "test.h"))
        #expect(fixture.organizer.group(for: "test.b") == .hidden)
        #expect(fixture.organizer.hidden == ["test.b", "test.h"])
        #expect(!fixture.organizer.collapsed)
        #expect(fixture.probe.releases == 1)
        // 跨组移动会立即异步重建收纳，等它完成后再验证下一次移动。
        try #require(await orderingEventually { fixture.organizer.collapsed && !fixture.organizer.busy })
        #expect(!fixture.tray.isPresented)
        #expect(fixture.organizer.moveApplication("test.b", to: .retained, before: "test.r"))
        #expect(fixture.organizer.group(for: "test.b") == .retained)
        #expect(fixture.probe.orders.isEmpty)
    }

    @Test func protectedInventoryCannotBeReorderedAndExpandedSyncDoesNotStartHiding() async throws {
        let fixture = OrderingFixture(order: ["test.ermi", "test.c", "com.apple.controlcenter", "test.a", "test.b"])
        defer { fixture.cleanup() }
        await fixture.inventory.includeProtectedEntries()
        await fixture.organizer.refresh()
        // 即使上游扫描异常包含自身或系统项，修改入口与真实同步仍须独立守住保护边界。
        #expect(fixture.organizer.applications.contains { $0.id == "test.ermi" })
        #expect(!fixture.organizer.moveApplication("test.ermi", to: .folded))
        #expect(!fixture.organizer.moveApplication("com.apple.controlcenter", to: .folded))
        #expect(!fixture.organizer.moveApplication("test.r", to: .retained, before: "test.ermi"))
        fixture.organizer.applyMenuBarOrder()
        try #require(await orderingEventually { !fixture.organizer.busy && fixture.probe.orders.count == 1 })
        #expect(fixture.probe.orders == [["test.c", "test.a", "test.b", "test.h", "test.r"]])
        #expect(!fixture.organizer.collapsed)
        #expect(!fixture.tray.isPresented)
        #expect(fixture.probe.activations == 0)
        #expect(fixture.probe.releases == 0)
    }

    @Test(arguments: ["success", "failure", "cancelled"], [false, true])
    func explicitSystemSyncRestoresPreviousCollapseAndTrayState(result: String, show: Bool) async throws {
        let fixture = OrderingFixture(order: ["test.c", "test.a", "test.b", "test.h", "test.r"])
        defer { fixture.cleanup() }
        try await fixture.collapse(show: show)
        fixture.probe.hold = true
        if result == "failure" { fixture.probe.result = .failure("test sync failure") }
        if result == "cancelled" { fixture.probe.result = .cancelled }
        fixture.organizer.applyMenuBarOrder()
        #expect(fixture.organizer.sorting)
        #expect(fixture.organizer.busy)
        #expect(!fixture.organizer.collapsed)
        #expect(!fixture.tray.isPresented)
        #expect(fixture.probe.releases == 1)
        try #require(await orderingEventually { fixture.probe.pending != nil })
        #expect(fixture.probe.orders == [["test.c", "test.a", "test.b", "test.h", "test.r"]])
        // 连续同步请求不能并发拖动系统图标。
        fixture.organizer.applyMenuBarOrder()
        #expect(fixture.probe.orders.count == 1)
        #expect(!fixture.organizer.moveApplication("test.b", to: .folded, before: "test.c"))
        fixture.probe.finish()
        try #require(await orderingEventually { fixture.organizer.collapsed && !fixture.organizer.busy })
        #expect(fixture.tray.isPresented == show)
        #expect(fixture.probe.activations == 2)
        if result == "failure" {
            #expect(await orderingEventually { fixture.organizer.message.contains("test sync failure") })
        }
        #expect(fixture.defaults.stringArray(forKey: "icons.order") == ["test.c", "test.a", "test.b", "test.h", "test.r"])
    }

    @Test(arguments: ["expand", "disable", "stop", "appsChanged", "refresh"])
    func cancelledSystemSyncRejectsLateCompletion(action: String) async throws {
        let fixture = OrderingFixture(order: ["test.c", "test.a", "test.b"])
        defer { fixture.cleanup() }
        try await fixture.collapse(show: true)
        fixture.probe.hold = true
        fixture.organizer.applyMenuBarOrder()
        try #require(await orderingEventually { fixture.probe.pending != nil })
        switch action {
        case "expand": fixture.organizer.expand()
        case "disable": fixture.organizer.setEnabled(false)
        case "stop": fixture.organizer.stop()
        case "appsChanged": fixture.organizer.appsChanged()
        default: await fixture.organizer.refresh()
        }
        fixture.probe.finish()
        // 替身故意忽略 Task 取消并返回成功；必须由业务代次阻止迟到结果重新隐藏或弹窗。
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(10))
            #expect(!fixture.organizer.sorting)
            #expect(!fixture.organizer.busy)
            #expect(!fixture.organizer.collapsed)
            #expect(!fixture.tray.isPresented)
        }
        #expect(fixture.probe.activations == 1)
        #expect(fixture.probe.releases == 1)
    }
}
