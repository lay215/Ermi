import AppKit
@preconcurrency import ApplicationServices
import Testing
@testable import Ermi

private actor SuspendedTrayScan {
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<([MenuBarTrayEntry], [Int: Int]), Never>] = [:]
    private var observers: [Int: CheckedContinuation<Void, Never>] = [:]

    func scan() async -> ([MenuBarTrayEntry], [Int: Int]) {
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

    func finish(_ id: Int, entries: [MenuBarTrayEntry]) {
        pending.removeValue(forKey: id)?.resume(returning: (entries, [:]))
    }
}

private actor TrayActions {
    private(set) var performed: [(UUID, String)] = []

    func record(_ entry: MenuBarTrayEntry, action: String, result: Int32 = 0) -> Int32 {
        performed.append((entry.id, action))
        return result
    }
}

@MainActor
struct MenuBarTrayTests {
    private func entry(_ name: String = "App", bundle: String = "test.app", x: CGFloat? = nil, action: String? = kAXPressAction) -> MenuBarTrayEntry {
        // 无效 PID 仅创建不执行的 AX 引用；所有测试通过注入扫描、权限与动作，绝不请求真实权限。
        MenuBarTrayEntry(pid: -1, bundleID: bundle, name: name, label: name,
                         element: AXUIElementCreateApplication(-1), action: action,
                         frame: x.map { CGRect(x: $0, y: 0, width: 20, height: 24) })
    }

    @Test func applicationScopePreservesEachEntryAndMenuBarOrder() async {
        let right = entry("Same app", x: 300)
        let left = entry("Same app", x: 100)
        let unknownZ = entry("Zebra")
        let unknownA = entry("Alpha")
        let other = entry("Other", bundle: "test.other", x: 50)
        let tray = MenuBarTray(permissionCheck: { true },
                               scanOverride: { ([right, unknownZ, other, left, unknownA], [:]) })
        await tray.prepare(scope: .applications(["test.app"]))
        #expect(tray.entries.map(\.id) == [left.id, right.id, unknownA.id, unknownZ.id])
        #expect(!tray.isPresented)
        #expect(!tray.loading)
    }

    @Test func separatorScopeUsesRightEdgeAndExcludesUnknownFrame() async {
        let left = entry("Left", x: 10)
        let boundary = entry("Boundary", x: 80)
        let crossing = entry("Crossing", x: 90)
        let unknown = entry("Unknown")
        let tray = MenuBarTray(permissionCheck: { true },
                               scanOverride: { ([unknown, crossing, boundary, left], [:]) })
        await tray.prepare(scope: .leftOf(100))
        #expect(tray.entries.map(\.id) == [left.id, boundary.id])
    }

    @Test func newScanWinsWhenOldScanCompletesLast() async {
        let scans = SuspendedTrayScan()
        let firstEntry = entry("Old")
        let secondEntry = entry("Current", bundle: "test.current")
        let tray = MenuBarTray(permissionCheck: { true }, scanOverride: { await scans.scan() })
        let first = Task { await tray.prepare(scope: .applications(["test.app"])) }
        await scans.waitForScan(0)
        let second = Task { await tray.prepare(scope: .applications(["test.current"])) }
        await scans.waitForScan(1)
        await scans.finish(1, entries: [secondEntry])
        await second.value
        await scans.finish(0, entries: [firstEntry])
        await first.value
        #expect(tray.entries.map(\.id) == [secondEntry.id])
        #expect(!tray.loading)
    }

    @Test func closeRejectsLateScanWithoutDismissCallback() async {
        let scans = SuspendedTrayScan()
        let item = entry()
        let tray = MenuBarTray(permissionCheck: { true }, scanOverride: { await scans.scan() })
        var dismissed = false
        tray.onDismiss = { dismissed = true }
        let prepare = Task { await tray.prepare(scope: .applications(["test.app"])) }
        await scans.waitForScan(0)
        tray.close()
        await scans.finish(0, entries: [item])
        await prepare.value
        #expect(tray.entries.isEmpty)
        #expect(!tray.loading)
        #expect(!dismissed)
    }

    @Test func cancelledCallerRejectsLateScan() async {
        let scans = SuspendedTrayScan()
        let item = entry()
        let tray = MenuBarTray(permissionCheck: { true }, scanOverride: { await scans.scan() })
        let prepare = Task { await tray.prepare(scope: .applications(["test.app"])) }
        await scans.waitForScan(0)
        prepare.cancel()
        await scans.finish(0, entries: [item])
        await prepare.value
        #expect(tray.entries.isEmpty)
        #expect(!tray.loading)
    }

    @Test func permissionRevocationRejectsLateScan() async {
        let scans = SuspendedTrayScan()
        let item = entry()
        var authorized = true
        let tray = MenuBarTray(permissionCheck: { authorized }, scanOverride: { await scans.scan() })
        let prepare = Task { await tray.prepare(scope: .applications(["test.app"])) }
        await scans.waitForScan(0)
        authorized = false
        await scans.finish(0, entries: [item])
        await prepare.value
        #expect(!tray.authorized)
        #expect(tray.entries.isEmpty)
        #expect(!tray.loading)
    }

    @Test func closeCanRetainPreparedEntriesForReopening() async {
        let item = entry()
        let tray = MenuBarTray(permissionCheck: { true }, scanOverride: { ([item], [:]) })
        await tray.prepare(scope: .applications(["test.app"]))
        tray.close(clearEntries: false)
        #expect(tray.entries.map(\.id) == [item.id])
        tray.close()
        #expect(tray.entries.isEmpty)
    }

    @Test func activatesExactSelectedElementOnceAfterPreparation() async {
        let actions = TrayActions()
        let first = entry("First", x: 0)
        let second = entry("Second", x: 40, action: kAXShowMenuAction)
        var preparedID: UUID?
        var completedID: UUID?
        let tray = MenuBarTray(permissionCheck: { true }, identityCheck: { _, _ in preparedID != nil },
                               scanOverride: { ([first, second], [:]) },
                               actionOverride: { await actions.record($0, action: $1) })
        tray.beforeActivate = { item in preparedID = item.id; return true }
        tray.afterActivate = { item in completedID = item.id }
        await tray.prepare(scope: .applications(["test.app"]))
        await tray.activate(second)
        let performed = await actions.performed
        #expect(performed.count == 1)
        #expect(performed.first?.0 == second.id)
        #expect(performed.first?.1 == kAXShowMenuAction)
        #expect(preparedID == second.id)
        #expect(completedID == second.id)
        #expect(tray.entries.map(\.id) == [first.id, second.id])
        #expect(!tray.loading)
    }

    @Test func rechecksPermissionAfterPreparingRealMenuBar() async {
        let actions = TrayActions()
        let item = entry()
        var authorized = true
        var completed = false
        let tray = MenuBarTray(permissionCheck: { authorized }, identityCheck: { _, _ in true },
                               scanOverride: { ([item], [:]) },
                               actionOverride: { await actions.record($0, action: $1) })
        tray.beforeActivate = { _ in authorized = false; return true }
        tray.afterActivate = { _ in completed = true }
        await tray.prepare(scope: .applications(["test.app"]))
        await tray.activate(item)
        #expect(await actions.performed.isEmpty)
        #expect(!completed)
        #expect(!tray.authorized)
        #expect(tray.entries.isEmpty)
    }

    @Test func processIdentityChangePreventsActivation() async {
        let actions = TrayActions()
        let item = entry()
        var prepared = false
        let tray = MenuBarTray(permissionCheck: { true }, identityCheck: { _, _ in !prepared },
                               scanOverride: { ([item], [:]) },
                               actionOverride: { await actions.record($0, action: $1) })
        tray.beforeActivate = { _ in prepared = true; return true }
        await tray.prepare(scope: .applications(["test.app"]))
        await tray.activate(item)
        #expect(await actions.performed.isEmpty)
        #expect(tray.failed)
        #expect(!tray.loading)
    }

    @Test func rejectedPreparationStillClearsRevokedPermission() async {
        let actions = TrayActions()
        let item = entry()
        var authorized = true
        let tray = MenuBarTray(permissionCheck: { authorized }, identityCheck: { _, _ in true },
                               scanOverride: { ([item], [:]) },
                               actionOverride: { await actions.record($0, action: $1) })
        tray.beforeActivate = { _ in authorized = false; return false }
        await tray.prepare(scope: .applications(["test.app"]))
        await tray.activate(item)
        #expect(await actions.performed.isEmpty)
        #expect(!tray.authorized)
        #expect(tray.entries.isEmpty)
        #expect(!tray.loading)
    }

    @Test func closingDuringPreparationPreventsLateActivation() async {
        let actions = TrayActions()
        let item = entry()
        let tray = MenuBarTray(permissionCheck: { true }, identityCheck: { _, _ in true },
                               scanOverride: { ([item], [:]) },
                               actionOverride: { await actions.record($0, action: $1) })
        tray.beforeActivate = { _ in tray.close(clearEntries: false); return true }
        await tray.prepare(scope: .applications(["test.app"]))
        await tray.activate(item)
        #expect(await actions.performed.isEmpty)
        #expect(!tray.loading)
    }

    @Test func unsupportedAndStaleEntriesCannotRunActions() async {
        let actions = TrayActions()
        let unsupported = entry("Unsupported", action: nil)
        let stale = entry("Stale")
        var preparations = 0
        let tray = MenuBarTray(permissionCheck: { true }, identityCheck: { _, _ in true },
                               scanOverride: { ([unsupported], [:]) },
                               actionOverride: { await actions.record($0, action: $1) })
        tray.beforeActivate = { _ in preparations += 1; return true }
        await tray.prepare(scope: .applications(["test.app"]))
        await tray.activate(unsupported)
        await tray.activate(stale)
        #expect(preparations == 0)
        #expect(await actions.performed.isEmpty)
    }

    @Test func ambiguousAXFailureDoesNotRetryOrReportSuccess() async {
        let actions = TrayActions()
        let item = entry()
        var completed = false
        let tray = MenuBarTray(permissionCheck: { true }, identityCheck: { _, _ in true },
                               scanOverride: { ([item], [:]) },
                               actionOverride: { await actions.record($0, action: $1, result: AXError.cannotComplete.rawValue) })
        tray.afterActivate = { _ in completed = true }
        await tray.prepare(scope: .applications(["test.app"]))
        await tray.activate(item)
        #expect(await actions.performed.count == 1)
        #expect(!completed)
        #expect(tray.failed)
        #expect(!tray.message.isEmpty)
        #expect(tray.entries.map(\.id) == [item.id])
    }

    @Test func refreshUsesOrganizerAndPermissionRequestIsExplicit() async {
        var authorized = false
        var requests = 0
        var refreshes = 0
        let tray = MenuBarTray(permissionCheck: { authorized },
                               permissionRequest: { requests += 1; authorized = true; return true },
                               scanOverride: { ([], [:]) })
        tray.onRefresh = { refreshes += 1 }
        await tray.prepare(scope: .applications([]))
        #expect(requests == 0)
        tray.refreshFromUser()
        #expect(requests == 1)
        #expect(refreshes == 1)
    }

    @Test func emptyAndReadFailureHaveDifferentStates() async {
        let empty = MenuBarTray(permissionCheck: { true }, scanOverride: { ([], [:]) })
        let failed = MenuBarTray(permissionCheck: { true }, scanOverride: { ([], [-25204: 1]) })
        await empty.prepare(scope: .applications([]))
        await failed.prepare(scope: .applications([]))
        #expect(!empty.failed)
        #expect(failed.failed)
        #expect(empty.message != failed.message)
        #expect(failed.messageHelp.contains("-25204"))
    }

    @Test func rowLayoutClampsToAnchorScreenAndKeepsOneRow() {
        let screen = CGRect(x: -1200, y: 500, width: 1200, height: 800)
        let visible = CGRect(x: -1200, y: 500, width: 1200, height: 776)
        let anchor = CGRect(x: -80, y: 1276, width: 24, height: 24)
        let small = MenuBarTray.layout(anchor: anchor, screen: screen, visible: visible, entryCount: 2, showsMessage: false)
        let overflow = MenuBarTray.layout(anchor: anchor, screen: screen, visible: visible, entryCount: 80, showsMessage: false)
        let left = MenuBarTray.layout(anchor: CGRect(x: -1190, y: 1276, width: 24, height: 24),
                                     screen: screen, visible: visible, entryCount: 8, showsMessage: false)
        #expect(small.maxX == anchor.maxX)
        #expect(small.maxY < anchor.minY)
        #expect(small.height == 36)
        #expect(overflow.height == small.height)
        #expect(overflow.width == screen.width - 16)
        #expect(overflow.minX >= screen.minX)
        #expect(overflow.maxX <= screen.maxX)
        #expect(left.minX >= screen.minX)
    }

    @Test func anchorClickIsReservedForToggleAndOutsideClickDismisses() {
        let anchor = CGRect(x: 900, y: 800, width: 24, height: 24)
        let panel = CGRect(x: 700, y: 758, width: 224, height: 36)
        #expect(!MenuBarTray.shouldDismiss(at: CGPoint(x: 910, y: 810), panelFrame: panel, anchor: anchor))
        #expect(!MenuBarTray.shouldDismiss(at: CGPoint(x: 800, y: 770), panelFrame: panel, anchor: anchor))
        #expect(MenuBarTray.shouldDismiss(at: CGPoint(x: 600, y: 700), panelFrame: panel, anchor: anchor))
    }
}
