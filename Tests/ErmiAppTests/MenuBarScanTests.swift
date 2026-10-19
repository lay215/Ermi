import Foundation
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

}
