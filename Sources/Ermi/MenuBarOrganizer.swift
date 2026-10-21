import AppKit
@preconcurrency import ApplicationServices
import Observation
import ErmiMenuBarBridge
import ErmiCore

struct MenuBarApplication: Identifiable, Sendable {
    let id: String
    let name: String
    let count: Int
    var entryIDs: [String] = []
}

enum MenuBarIconGroup: String, CaseIterable {
    case retained, folded, hidden
}

// 加载指示只负责显示，鼠标仍交给整个菜单栏按钮，避免小转圈截获重复点击。
private final class MenuBarPreparationIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// 将系统隐藏接口集中在一处，回归测试可验证真实收纳流程而不改动用户的菜单栏。
@MainActor
struct MenuBarVisibilityAccess {
    var native: Bool
    var available: () -> Bool
    var runningBundleIDs: () -> Set<String>
    var ownBundleID: () -> String?
    var activate: ([String], @escaping @MainActor (Any?, Error?) -> Void) -> Void
    var release: (Any) -> Void

    static let system = MenuBarVisibilityAccess(
        native: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
        available: { ErmiVisibilityAvailable() },
        runningBundleIDs: { Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier)) },
        ownBundleID: { Bundle.main.bundleIdentifier },
        activate: { bundles, completion in
            ErmiVisibilityActivate(bundles) { handle, error in
                // ObjC bridge 的 finish 固定派发到主队列；不透明断言只在该队列接收、保存和释放。
                nonisolated(unsafe) let receivedHandle = handle
                MainActor.assumeIsolated { completion(receivedHandle, error) }
            }
        },
        release: { ErmiVisibilityRelease($0) }
    )
}

@MainActor @Observable
final class MenuBarOrganizer: NSObject {
    private(set) var enabled: Bool
    private(set) var collapsed = false
    private var collapsing = false
    private var preparingTray = false
    private(set) var sorting = false
    var busy: Bool { preparingTray || collapsing || sorting }
    private(set) var refreshing = false
    private(set) var authorized: Bool
    private(set) var applications: [MenuBarApplication] = []
    private(set) var folded: Set<String>
    private(set) var hidden: Set<String>
    private(set) var applicationOrder: [String]
    // 逐入口偏好绑定当前 AX 元素，不能把运行期 UUID 持久化后误用于重启后的新入口。
    private(set) var entryOrder: [String] = []
    var orderedIcons: [MenuBarApplicationIcon] {
        let values = orderedApplications.flatMap { MenuBarApplicationIcon.items(for: $0) }
        let ranks = Dictionary(uniqueKeysWithValues: entryOrder.enumerated().map { ($0.element, $0.offset) })
        return values.enumerated().sorted {
            let left = ranks[$0.element.id] ?? Int.max
            let right = ranks[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    var orderedApplications: [MenuBarApplication] {
        let ranks = Dictionary(uniqueKeysWithValues: applicationOrder.enumerated().map { ($0.element, $0.offset) })
        // 未自定义时仍用原清单顺序；新出现的 App 排在已保存项后面，不覆盖退出 App 的偏好位置。
        return applications.enumerated().sorted {
            let left = ranks[$0.element.id] ?? Int.max
            let right = ranks[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    private(set) var delay: Int
    var trayPresented: Bool { tray.isPresented }
    var originalIconsAuthorized: Bool { tray.screenCaptureAuthorized }
    var message = ""
    var native: Bool { visibility.native }
    var available: Bool { !native || visibility.available() }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let visibility: MenuBarVisibilityAccess
    @ObservationIgnored private let orderAccess: MenuBarOrderAccess
    @ObservationIgnored private let permissionCheck: () -> Bool
    @ObservationIgnored private let permissionRequest: () -> Bool
    @ObservationIgnored private var needsRefresh = true
    @ObservationIgnored private let scanOverride: (@Sendable () async -> ([MenuBarApplication], [Int: Int]))?
    @ObservationIgnored private var toggleItem: NSStatusItem?
    @ObservationIgnored private var preparationIndicator: NSProgressIndicator?
    @ObservationIgnored private var separator: NSStatusItem?
    @ObservationIgnored private var handle: Any?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var activationTimeout: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var orderTask: Task<Void, Never>?
    @ObservationIgnored private var openingTrayRequested = false
    @ObservationIgnored private var collapseRequested = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var scanRevision = 0
    @ObservationIgnored private var scanTask: Task<([MenuBarApplication], [Int: Int]), Never>?
    @ObservationIgnored private let tray: MenuBarTray
    // macOS 自身的控件无法按 App 安全拆分，始终保持可见。
    private static let systemOwners = MenuBarVisibilityPlan.systemOwners

    init(
        defaults: UserDefaults = .standard,
        permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        permissionRequest: @escaping () -> Bool = { MenuBarOrganizer.requestSystemPermission() },
        scanOverride: (@Sendable () async -> ([MenuBarApplication], [Int: Int]))? = nil,
        tray: MenuBarTray? = nil,
        visibility: MenuBarVisibilityAccess = .system,
        orderAccess: MenuBarOrderAccess = .system
    ) {
        self.defaults = defaults
        self.visibility = visibility
        self.orderAccess = orderAccess
        self.permissionCheck = permissionCheck
        self.permissionRequest = permissionRequest
        self.scanOverride = scanOverride
        let tray = tray ?? MenuBarTray(permissionCheck: permissionCheck, permissionRequest: permissionRequest)
        self.tray = tray
        authorized = permissionCheck()
        enabled = defaults.bool(forKey: "icons.enabled")
        let savedHidden = Set(defaults.stringArray(forKey: "icons.hidden") ?? [])
        hidden = savedHidden
        // 旧配置没有隐藏组时保持原行为；手工配置冲突时隐藏优先，避免隐藏项意外出现在展开栏。
        folded = Set(defaults.stringArray(forKey: "icons.folded") ?? []).subtracting(savedHidden)
        var seen = Set<String>()
        applicationOrder = (defaults.stringArray(forKey: "icons.order") ?? []).filter {
            // 仅 bundleID 是跨重启身份；UUID、PID、动态标题和屏幕坐标不能用作持久化顺序键。
            !$0.isEmpty && $0 != visibility.ownBundleID() && !Self.systemOwners.contains($0) && seen.insert($0).inserted
        }
        let saved = defaults.integer(forKey: "icons.delay")
        delay = [0, 5, 10, 30, 60].contains(saved) ? saved : 0
        super.init()
        tray.setApplicationOrder(applicationOrder)
        tray.onMoveEntry = { [weak self] id, before in
            guard let self, self.collapsed, self.tray.isPresented else { return false }
            return self.moveEntry(id, to: .folded, before: before)
        }
        tray.onMoveApplication = { [weak self] id, before in
            guard let self, self.collapsed, self.tray.isPresented,
                  self.group(for: id) == .folded,
                  before.map({ self.group(for: $0) == .folded }) ?? true else { return false }
            return self.moveApplication(id, to: .folded, before: before)
        }
        tray.onDismiss = { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            // 关闭展开栏只关闭代理界面，原收纳断言与分隔线位置始终保持。
            self.updateButton()
        }
        tray.onRefresh = { [weak self] in
            // 原生隐藏断言可能让 AX 入口不可读；刷新必须先恢复，再重新建立收纳快照。
            self?.needsRefresh = true
            self?.expand()
            self?.showTray()
        }
        tray.beforeActivate = { [weak self] _ in
            guard let self, self.enabled, self.collapsed, !self.busy, self.permissionCheck() else { return false }
            // 缓存的是原 AX 元素，直接执行其动作；不能为一次点击解除整组隐藏，也不自动展开作失败回退。
            self.timer?.cancel()
            return true
        }
        tray.afterActivate = { [weak self] _ in self?.updateButton() }
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // 新 App 出现时先解除限制，避免白名单把尚未分组的入口意外隐藏。
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appsChanged), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        if enabled {
            installItems()
            // 启动恢复已保存的收纳分组；只准备隐藏，不自动弹出展开栏或请求权限。
            prepareCollapse(openingTray: false, requestPermissionIfNeeded: false)
        }
    }

    func setEnabled(_ value: Bool, requestPermissionIfNeeded: Bool = true) {
        invalidateScan()
        tray.close()
        expand()
        enabled = value
        defaults.set(value, forKey: "icons.enabled")
        if value {
            installItems()
            // 只有用户主动启用才弹授权；自动诊断显式关闭此入口，保持探针无授权副作用。
            if requestPermissionIfNeeded && native && !permissionCheck() { requestPermission() }
            prepareCollapse(openingTray: false, requestPermissionIfNeeded: false)
        } else { removeItems() }
    }

    func setDelay(_ value: Int) {
        guard [0, 5, 10, 30, 60].contains(value) else { return }
        delay = value
        defaults.set(value, forKey: "icons.delay")
        timer?.cancel()
        // 改设置不会立即隐藏图标；下次用户展开后才开始计时。
    }

    @discardableResult
    func setFolded(_ id: String, _ value: Bool) -> Bool {
        setGroup(id, value ? .folded : .retained)
    }

    func group(for id: String) -> MenuBarIconGroup {
        hidden.contains(id) ? .hidden : (folded.contains(id) ? .folded : .retained)
    }

    @discardableResult
    func setGroup(_ id: String, _ group: MenuBarIconGroup) -> Bool {
        // 拖放与点击共用同一入口；只接受当前已识别 App 的跨组移动，停用、扫描或撤权时不写入分组。
        guard enabled, available, !busy, !refreshing, permissionCheck(),
              applications.contains(where: { $0.id == id }), self.group(for: id) != group,
              id != visibility.ownBundleID(), !Self.systemOwners.contains(id),
              group != .hidden || native else { return false }
        // 换组先释放旧白名单，再按新分组立即收纳；改回保留后也必须让该 App 恢复显示。
        expand()
        folded.remove(id)
        hidden.remove(id)
        if group == .folded { folded.insert(id) }
        if group == .hidden { hidden.insert(id) }
        defaults.set(folded.sorted(), forKey: "icons.folded")
        defaults.set(hidden.sorted(), forKey: "icons.hidden")
        message = "分组已更新。"
        prepareCollapse(openingTray: false, requestPermissionIfNeeded: false)
        return true
    }

    func requestPermission() {
        // 即使系统立即返回已授权，列表也需要重新读取；不能只比较授权布尔值。
        authorized = permissionRequest()
        needsRefresh = true
        message = authorized ? "权限已识别，正在准备刷新图标。" : "请在系统设置中允许当前 Ermi，返回后自动刷新图标。"
    }

    @discardableResult
    func moveApplication(_ id: String, to group: MenuBarIconGroup, before targetID: String? = nil) -> Bool {
        // 两个界面共用身份校验；按目标 bundleID 插入，搜索后的局部下标不会误改完整分组。
        guard enabled, native, available, !busy, !refreshing, permissionCheck(),
              applications.contains(where: { $0.id == id }), id != visibility.ownBundleID(),
              !Self.systemOwners.contains(id), targetID != id else { return false }
        if let targetID {
            guard applications.contains(where: { $0.id == targetID }), self.group(for: targetID) == group,
                  targetID != visibility.ownBundleID(), !Self.systemOwners.contains(targetID) else { return false }
        }
        let originalGroup = self.group(for: id)
        let visibleGroupIDs = orderedApplications.filter { self.group(for: $0.id) == group }.map(\.id)
        var desiredGroupIDs = visibleGroupIDs.filter { $0 != id }
        let groupIndex = targetID.flatMap { desiredGroupIDs.firstIndex(of: $0) } ?? desiredGroupIDs.endIndex
        desiredGroupIDs.insert(id, at: groupIndex)
        guard originalGroup != group || desiredGroupIDs != visibleGroupIDs else { return false }
        // 换组立即重新收纳；纯排序只改缓存，不释放隐藏断言或执行原图标动作。
        if originalGroup != group, !setGroup(id, group) { return false }
        var order = applicationOrder
        let known = Set(order)
        order.append(contentsOf: orderedApplications.map(\.id).filter {
            !known.contains($0) && $0 != visibility.ownBundleID() && !Self.systemOwners.contains($0)
        })
        order.removeAll { $0 == id }
        let index = targetID.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
        order.insert(id, at: index)
        applicationOrder = order
        defaults.set(order, forKey: "icons.order")
        tray.setApplicationOrder(order)
        message = "顺序已保存并更新展开栏；点击「同步菜单栏顺序」应用到顶部。"
        return true
    }

    func canShiftApplication(_ id: String, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1, enabled, native, available, !busy, !refreshing,
              permissionCheck(), id != visibility.ownBundleID(), !Self.systemOwners.contains(id) else { return false }
        let ids = orderedApplications.filter { group(for: $0.id) == group(for: id) }.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return false }
        return ids.indices.contains(index + offset)
    }

    @discardableResult
    func shiftApplication(_ id: String, by offset: Int) -> Bool {
        guard canShiftApplication(id, by: offset) else { return false }
        let group = group(for: id)
        let ids = orderedApplications.filter { self.group(for: $0.id) == group }.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return false }
        let insertion = offset < 0 ? index - 1 : index + 2
        return moveApplication(id, to: group, before: ids.indices.contains(insertion) ? ids[insertion] : nil)
    }

    @discardableResult
    func moveEntry(_ id: String, to group: MenuBarIconGroup, before targetID: String? = nil) -> Bool {
        guard enabled, native, available, !busy, !refreshing, permissionCheck(), id != targetID,
              let icon = orderedIcons.first(where: { $0.id == id }),
              icon.application.id != visibility.ownBundleID(), !Self.systemOwners.contains(icon.application.id) else { return false }
        if let targetID {
            guard let target = orderedIcons.first(where: { $0.id == targetID }),
                  self.group(for: target.application.id) == group,
                  target.application.id != visibility.ownBundleID(), !Self.systemOwners.contains(target.application.id) else { return false }
        }
        let originalGroup = self.group(for: icon.application.id)
        // 系统隐藏接口按 App 生效；多入口跨组拖动不能暗中移动另一项，整 App 改组另走明确按钮。
        if originalGroup != group && icon.application.count > 1 {
            message = "同一 App 的入口可独立排序；跨组请使用「移动整个 App」按钮。"
            return false
        }
        let current = orderedIcons.filter { self.group(for: $0.application.id) == group }.map(\.id)
        var desired = current.filter { $0 != id }
        desired.insert(id, at: targetID.flatMap { desired.firstIndex(of: $0) } ?? desired.endIndex)
        guard originalGroup != group || current != desired else { return false }
        // 只移除和插入被拖动的入口，另一入口的位置及精确 AX 动作保持不变。
        var order = orderedIcons.map(\.id).filter { $0 != id }
        order.insert(id, at: targetID.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
        if originalGroup != group, !setGroup(icon.application.id, group) { return false }
        entryOrder = order
        tray.setEntryOrder(order)
        message = "入口顺序已更新；点击「同步菜单栏顺序」让 macOS 保存顶部位置。"
        return true
    }

    func canShiftEntry(_ id: String, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1, enabled, native, available, !busy, !refreshing, permissionCheck(),
              let icon = orderedIcons.first(where: { $0.id == id }),
              icon.application.id != visibility.ownBundleID(), !Self.systemOwners.contains(icon.application.id) else { return false }
        let ids = orderedIcons.filter { group(for: $0.application.id) == group(for: icon.application.id) }.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return false }
        return ids.indices.contains(index + offset)
    }

    @discardableResult
    func shiftEntry(_ id: String, by offset: Int) -> Bool {
        guard canShiftEntry(id, by: offset), let icon = orderedIcons.first(where: { $0.id == id }) else { return false }
        let group = group(for: icon.application.id)
        let ids = orderedIcons.filter { self.group(for: $0.application.id) == group }.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return false }
        let insertion = offset < 0 ? index - 1 : index + 2
        return moveEntry(id, to: group, before: ids.indices.contains(insertion) ? ids[insertion] : nil)
    }

    func applyMenuBarOrder() {
        guard enabled, native, available, !busy, !refreshing, permissionCheck(),
              !applicationOrder.isEmpty || !entryOrder.isEmpty else { return }
        let order = entryOrder.isEmpty ? orderedApplications.map(\.id).filter {
            $0 != visibility.ownBundleID() && !Self.systemOwners.contains($0)
        } : orderedIcons.map(\.id)
        guard !order.isEmpty else { return }
        let restoreCollapsed = collapsed
        let restoreTray = tray.isPresented
        // 只有显式同步才临时恢复真实菜单栏；拖拽本地顺序与点击原图标均不会走这条路径。
        expand()
        let request = generation
        sorting = true
        message = "正在同步菜单栏顺序…"
        updateButton()
        orderTask = Task { [weak self] in
            guard let self, !Task.isCancelled, request == self.generation else { return }
            let result = await self.orderAccess.apply(order)
            guard !Task.isCancelled, request == self.generation, self.enabled else { return }
            self.sorting = false
            let report: String
            switch result {
            case .success(let moved):
                report = "当前菜单栏顺序已核对，移动了 \(moved) 个入口。"
            case .failure(let reason):
                report = "顶部顺序未完全同步：\(L(reason)) 设置与展开栏顺序已保存，可重试同步。"
            case .cancelled:
                report = "已取消菜单栏排序，顶部可能保留已完成的调整。"
            }
            let shouldOpen = restoreTray || self.openingTrayRequested
            if restoreCollapsed || shouldOpen {
                self.collapse(requestPermissionIfNeeded: false, openingTray: shouldOpen)
            }
            let restoration = self.generation
            // 等待原收纳恢复完成再报告同步结果，避免普通收纳回调覆盖真实排序失败信息。
            while self.collapsing && restoration == self.generation && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled, restoration == self.generation else { return }
            self.message = report + (restoreCollapsed && !self.collapsed ? " " + self.message : "")
            self.orderTask = nil
            self.updateButton()
        }
    }

    func requestOriginalIconsPermission() { tray.requestOriginalIconsPermission() }
    func synchronizeIconPermission() { tray.synchronizeIconPermission() }

    static func requestSystemPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        // 系统授权提示只在首次出现；之后点击仍需直达设置，避免看似没有反应。
        if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return trusted
    }

    func refreshFromUser() async {
        guard permissionCheck() else { requestPermission(); return }
        await refresh()
    }

    var permissionName: String { native ? "设备控制和数据访问" : "辅助功能" }

    func synchronizePermission() async {
        tray.synchronizeIconPermission()
        // 系统授权弹窗异步返回；页面可见期间同步变化，避免授权后按钮仍被旧状态禁用。
        // 权限未变化时不刷新列表，防止轮询不断解除用户的收纳状态。
        guard permissionCheck() != authorized || (needsRefresh && !busy && !refreshing) else { return }
        let restoreCollapse = collapseRequested
        let refreshedGeneration = generation + 1
        await refresh()
        // 首次启动尚未授权时保留恢复意图；授权返回后应用配置，显式展开则不会被轮询重新收纳。
        if restoreCollapse, !Task.isCancelled, generation == refreshedGeneration {
            prepareCollapse(openingTray: false, requestPermissionIfNeeded: false)
        }
    }

    func refresh() async {
        // 设置页的显式刷新取消尚未完成的打开意图；入口内部扫描不走此恢复入口。
        guard !Task.isCancelled else { return }
        expand()
        _ = await refreshInventory()
    }

    private func refreshInventory() async -> Bool {
        // 新请求替换旧扫描；关闭功能、退出或 App 集合变化后，旧 AX 结果不能回填。
        guard !Task.isCancelled else { return false }
        invalidateScan()
        let request = scanRevision
        authorized = permissionCheck()
        guard authorized else { applications = []; message = "Ermi 尚未获得\(permissionName)权限。系统中已允许时，请退出并重新打开当前 Ermi。"; return false }
        refreshing = true
        defer {
            if request == scanRevision { refreshing = false; scanTask = nil }
        }
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String, String)? in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.bundleURL?.pathExtension == "app", let id = app.bundleIdentifier,
                  !Self.systemOwners.contains(id) else { return nil }
            return (app.processIdentifier, id, app.localizedName ?? id)
        }
        // AX 跨进程调用有超时，放到后台，避免一个无响应 App 卡住整个设置页。
        let scanOverride = self.scanOverride
        let scan = Task.detached(priority: .userInitiated) {
            // 可注入延迟扫描验证退出、撤权与请求竞争；默认仍读取真实 AX 菜单栏。
            if let scanOverride { return await scanOverride() }
            var errors: [Int: Int] = [:]
            let found = apps.compactMap { pid, id, name -> MenuBarApplication? in
                guard !Task.isCancelled else { return nil }
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.15)
                var raw: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &raw)
                guard status == .success else {
                    errors[Int(status.rawValue), default: 0] += 1
                    return nil
                }
                guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
                let bar = unsafeDowncast(raw, to: AXUIElement.self)
                var children: CFTypeRef?
                let childStatus = AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children)
                guard childStatus == .success else {
                    errors[Int(childStatus.rawValue), default: 0] += 1
                    return nil
                }
                guard let rawItems = children as? [AXUIElement] else { return nil }
                let items = MenuBarEntryFilter.managedItems(rawItems, bundleID: id)
                guard !items.isEmpty else { return nil }
                var seen = Set<String>()
                let entryIDs = items.map { MenuBarEntryIdentity.shared.id(pid: pid, bundleID: id, element: $0) }
                    .filter { seen.insert($0).inserted }
                return MenuBarApplication(id: id, name: name, count: entryIDs.count, entryIDs: entryIDs)
            }
            return (found, errors)
        }
        scanTask = scan
        let result = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
        guard request == scanRevision, !Task.isCancelled else { return false }
        // 授权可能在后台读取期间撤销，完成时重新核实，不展示曾经有权限读到的旧入口。
        authorized = permissionCheck()
        guard authorized else {
            applications = []
            message = "权限已撤销，请重新授权后刷新图标列表。"
            return false
        }
        // 同 bundle 的多个进程也共享系统隐藏范围；合并 App 外壳但保留每个精确入口，避免误认成两个单入口 App。
        applications = Dictionary(grouping: result.0, by: \.id).values.compactMap { values in
            guard let first = values.first else { return nil }
            let previous = applications.first { $0.id == first.id }?.entryIDs ?? []
            let ranks = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element, $0.offset) })
            // 显示序号沿用已识别入口，扫描返回顺序变化不会把“入口 1”的标签换给“入口 2”。
            let identities = values.flatMap(\.entryIDs).enumerated().sorted {
                let left = ranks[$0.element] ?? Int.max
                let right = ranks[$1.element] ?? Int.max
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
            return MenuBarApplication(id: first.id, name: first.name, count: values.reduce(0) { $0 + $1.count },
                                      entryIDs: identities)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // 只有完整且仍有效的扫描能清除刷新标记；取消后的下一次点击必须重新读取。
        needsRefresh = false
        // 区分“权限已识别但接口读取失败”与尚未授权，不再把所有空列表归因于权限。
        if applications.isEmpty {
            let failures = result.1.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "、")
            message = "权限已识别，已检查 \(apps.count) 个运行 App，但未读到菜单栏入口。"
                + (failures.isEmpty ? "" : " 系统读取结果：\(failures)。")
        } else {
            message = "已读取 \(applications.count) 个 App。分组更改后自动应用。"
        }
        return true
    }

    func collapse(requestPermissionIfNeeded: Bool = true, openingTray: Bool = false) {
        guard enabled, available, !busy, !refreshing, !collapsed else { return }
        collapseRequested = true
        tray.close()
        timer?.cancel()
        let scope: MenuBarTrayScope
        let plan: MenuBarVisibilityPlan?
        if !native {
            guard arrangementValid else { message = "请按住 ⌘，将分隔线拖到展开箭头左侧，再重试。"; return }
            // 旧系统按分隔线位置收纳；不能把仅供 macOS 27 使用的 folded 配置当作它的分组来源。
            scope = .leftOf(separator?.button?.window?.frame.minX ?? 0)
            plan = nil
        } else {
            authorized = permissionCheck()
            guard authorized else {
                if requestPermissionIfNeeded { requestPermission() }
                return
            }
            let running = visibility.runningBundleIDs()
            guard let own = visibility.ownBundleID() else { message = "请从构建后的 Ermi.app 启动图标整理。"; return }
            let visibility = MenuBarVisibilityPlan(selected: folded.union(hidden), discovered: Set(applications.map(\.id)), running: running, own: own)
            guard !visibility.hidden.isEmpty else { message = "请先将至少一个正在运行的 App 移至收起或隐藏。"; return }
            // 两组共同从菜单栏收纳，只有「收起」组可在下方访问；仅有隐藏组时允许空展开栏。
            // 沿用同一资格过滤，已退出、不可读、系统及自身入口不能混入隐藏或代理点击范围。
            scope = .applications(visibility.hidden.intersection(folded).subtracting(hidden))
            plan = visibility
        }
        generation += 1
        let request = generation
        collapsing = true
        openingTrayRequested = openingTray
        updateButton()
        collapseTask = Task { [weak self] in
            guard let self, !Task.isCancelled, request == self.generation else { return }
            // 隐藏前保存准确 AX 元素与位置，避免隐藏后扫描为空，或把常驻项混入下方横条。
            await self.tray.prepare(scope: scope)
            guard !Task.isCancelled, request == self.generation, self.enabled else { return }
            self.applyCollapse(plan: plan, request: request)
        }
    }

    private func applyCollapse(plan: MenuBarVisibilityPlan?, request: Int) {
        if !native {
            separator?.length = hiddenLength
            collapsing = false
            collapsed = true
            if openingTrayRequested { presentTray() }
            openingTrayRequested = false
            updateButton()
            return
        }
        guard let plan, permissionCheck() else { expand(); return }
        // 私有接口可能不回调；超时解除等待，迟到的成功仍由 generation 校验释放。
        activationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, request == self.generation else { return }
            self.expand()
            self.message = "系统响应超时，已取消收起请求。"
        }
        let release = visibility.release
        visibility.activate(plan.allowed.sorted()) { [weak self] newHandle, error in
            guard let self, request == self.generation else {
                // 用户可能在异步完成前点击展开或退出；过期结果必须立即释放。
                if let newHandle { release(newHandle) }
                return
            }
            // 激活期间也可能撤权；此时释放迟到断言，不能继续收纳或弹出缓存入口。
            guard self.permissionCheck() else {
                if let newHandle { release(newHandle) }
                self.expand()
                self.authorized = false
                self.needsRefresh = true
                self.message = "权限已撤销，请重新授权后刷新图标列表。"
                return
            }
            self.collapsing = false
            self.activationTimeout?.cancel()
            if let newHandle {
                self.handle = newHandle
                self.collapsed = true
                self.message = "已收起 \(plan.hidden.count) 个 App 的菜单栏入口。"
                if self.openingTrayRequested { self.presentTray() }
            } else {
                self.message = "收起失败，图标保持显示：\(error?.localizedDescription ?? "系统未接受请求")"
            }
            self.openingTrayRequested = false
            self.updateButton()
        }
    }

    func expand(automaticallyCollapse: Bool = false) {
        generation += 1
        collapseRequested = false
        if sorting { message = "已取消菜单栏排序，顶部可能保留已完成的调整。" }
        sorting = false
        orderTask?.cancel()
        orderTask = nil
        // 关闭、停用、刷新及桌面变化共用取消入口；内部清单读取不调用 expand，避免取消自身。
        if preparingTray { invalidateScan() }
        preparingTray = false
        collapsing = false
        openingTrayRequested = false
        preparationTask?.cancel()
        preparationTask = nil
        collapseTask?.cancel()
        timer?.cancel()
        activationTimeout?.cancel()
        tray.close()
        if let handle { visibility.release(handle); self.handle = nil }
        separator?.length = 20
        collapsed = false
        updateButton()
        if automaticallyCollapse { scheduleCollapse() }
    }

    func showTray() {
        guard enabled, available else { return }
        // 正在扫描、保存快照或申请隐藏时，后续点击只保留打开意图，不撤销工作。
        if busy { openingTrayRequested = true; updateButton(); return }
        if tray.isPresented { dismissTray(); return }
        authorized = permissionCheck()
        guard authorized else { requestPermission(); return }
        if collapsed { presentTray(); return }
        prepareCollapse(openingTray: true, requestPermissionIfNeeded: true)
    }

    private func prepareCollapse(openingTray: Bool, requestPermissionIfNeeded: Bool) {
        guard enabled, available, !busy, !collapsed else { return }
        // 自动入口与点击入口共用扫描和快照流程；打开横条是独立意图，后台恢复不能冒出弹窗。
        // 原生分组为空时无须后台扫描；旧系统仍以分隔线位置为准。
        guard openingTray || !native || !folded.union(hidden).isEmpty else { return }
        collapseRequested = true
        authorized = permissionCheck()
        guard authorized || !native else {
            if requestPermissionIfNeeded { requestPermission() }
            return
        }
        if native && (needsRefresh || refreshing || applications.isEmpty) {
            // 普通点击自行准备清单，无需先进入设置页；同步设置 busy 防止 Task 启动前重复排队。
            // 空清单允许下次主动点击重试，但不让设置页的定时同步无限重扫失败的 AX 接口。
            preparingTray = true
            openingTrayRequested = openingTray
            let request = generation
            updateButton()
            preparationTask = Task { [weak self] in
                guard let self, !Task.isCancelled, request == self.generation else { return }
                var refreshed = await self.refreshInventory()
                // App 启动通知可能早于它创建状态项；后台恢复最多补读三次，避免必须再点箭头。
                // 只等已配置、仍运行且尚未识别的 App；明确点击不受这段等待影响，失败也不无限轮询。
                if !openingTray {
                    for delay in [250, 500, 1000] {
                        guard refreshed, !Task.isCancelled, request == self.generation, self.enabled else { break }
                        let missing = self.folded.union(self.hidden)
                            .intersection(self.visibility.runningBundleIDs())
                            .subtracting(Self.systemOwners)
                            .subtracting(Set(self.applications.map(\.id)))
                            .subtracting(Set([self.visibility.ownBundleID()].compactMap { $0 }))
                        if missing.isEmpty || self.openingTrayRequested { break }
                        try? await Task.sleep(for: .milliseconds(delay))
                        guard !Task.isCancelled, request == self.generation else { return }
                        refreshed = await self.refreshInventory()
                    }
                }
                guard !Task.isCancelled, request == self.generation, self.enabled else { return }
                self.preparingTray = false
                self.preparationTask = nil
                // 自动扫描期间点击箭头可以追加打开意图；阶段切换时不能把该点击丢掉。
                let shouldOpen = self.openingTrayRequested
                self.openingTrayRequested = false
                if refreshed { self.collapse(requestPermissionIfNeeded: requestPermissionIfNeeded, openingTray: shouldOpen) }
                self.updateButton()
            }
        } else {
            collapse(requestPermissionIfNeeded: requestPermissionIfNeeded, openingTray: openingTray)
            updateButton()
        }
    }

    private func presentTray() {
        // 使用按钮本身的屏幕坐标，避免状态项宿主窗口在多屏下包含额外空间。
        let anchor = toggleItem?.button.flatMap { button in
            button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        }
        tray.show(anchor: anchor)
        updateButton()
        scheduleCollapse()
    }

    private func dismissTray() {
        // 状态项再次点击只关闭下方横条，保留当前收纳。
        tray.dismissFromUser()
        timer?.cancel()
        updateButton()
    }

    @objc func toggle() {
        showTray()
        // NSStatusBarButton 在 mouseUp 结束时会清除按下态，下一轮再同步持续的打开/准备态。
        DispatchQueue.main.async { [weak self] in self?.updateButton() }
    }

    private func installItems() {
        guard toggleItem == nil, available else { return }
        // 箭头使用 24pt 宽的独立全高点击区，收紧与相邻 Logo 的留白。
        let item = NSStatusBar.system.statusItem(withLength: 24)
        item.autosaveName = "ErmiIconToggle"
        item.behavior = []
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(toggle)
        toggleItem = item
        if let button = item.button {
            // 状态项由 AppKit 管理布局，使用明确尺寸与弹性边距，避免首次显示时子视图仍为零大小。
            let indicator = MenuBarPreparationIndicator(frame: NSRect(
                x: button.bounds.midX - 6, y: button.bounds.midY - 6, width: 12, height: 12
            ))
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isIndeterminate = true
            indicator.isDisplayedWhenStopped = false
            indicator.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            button.addSubview(indicator)
            preparationIndicator = indicator
        }
        if !native {
            let divider = NSStatusBar.system.statusItem(withLength: 20)
            divider.autosaveName = "ErmiIconSeparator"
            divider.behavior = []
            divider.isVisible = true
            divider.button?.title = "│"
            divider.button?.toolTip = "⌘ 拖动：左侧收纳，右侧常驻"
            separator = divider
        }
        updateButton()
    }

    private func updateButton() {
        guard let button = toggleItem?.button else { return }
        let title = sorting ? "正在同步菜单栏顺序…" : (busy ? "正在准备展开栏" : (tray.isPresented ? "收起展开栏" : "展开收纳图标"))
        // 图形与命中区域分离：24pt 原生全高按钮覆盖箭头与加载转圈，单色上下箭头表达横条开关状态。
        let symbol = tray.isPresented ? "chevron.up" : "chevron.down"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: L(title))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        button.image = busy ? nil : image
        button.title = ""
        button.imagePosition = .imageOnly
        if busy { preparationIndicator?.startAnimation(nil) }
        else { preparationIndicator?.stopAnimation(nil) }
        button.highlight(busy || tray.isPresented)
        button.setAccessibilityLabel(L(title))
        button.toolTip = L(busy ? "Ermi · 正在准备收纳图标" : (tray.isPresented ? "Ermi · 点击收起展开栏" : "Ermi · 点击在下方展开收纳图标"))
    }

    private var hiddenLength: CGFloat { min(10_000, max(500, (NSScreen.screens.map { $0.frame.width }.max() ?? 2000) * 2)) }
    private var arrangementValid: Bool {
        guard let divider = separator?.button?.window?.frame, let toggle = toggleItem?.button?.window?.frame else { return false }
        return divider.midX < toggle.midX
    }
    @objc private func displayChanged() {
        let restoreCollapse = collapseRequested
        expand()
        invalidateScan()
        // 屏幕布局变化使旧位置快照失效；重新准备，但不把系统通知当作用户要求展开全部。
        if restoreCollapse { prepareCollapse(openingTray: false, requestPermissionIfNeeded: false) }
    }
    @objc private func spaceChanged() {
        // 切换桌面取消弹窗意图；后台收纳仍可重建，迟到断言不得在新桌面弹出横条。
        if busy {
            let restoreCollapse = collapseRequested
            expand()
            if restoreCollapse { prepareCollapse(openingTray: false, requestPermissionIfNeeded: false) }
        } else { dismissTray() }
    }
    @objc func appsChanged(_ notification: Notification? = nil) {
        if notification?.name == NSWorkspace.didTerminateApplicationNotification, collapsed, !busy {
            // 退出只减少入口，不会新增被白名单误藏的 App；保留现有断言及旧系统分隔线宽度。
            // 不能标记 needsRefresh，否则设置页的权限轮询随后会调用 refresh 间接展开全部。
            guard !native || permissionCheck() else {
                authorized = false
                expand()
                needsRefresh = true
                message = "权限已撤销，请重新授权后刷新图标列表。"
                return
            }
            let running = visibility.runningBundleIDs()
            let terminated = notification?.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            applications.removeAll { !running.contains($0.id) }
            tray.removeTerminatedEntries(running: running, terminatedPID: terminated?.processIdentifier)
            updateButton()
            return
        }
        // 新 App、唤醒及准备中的入口变化须先撤销旧计划，再用新清单恢复收纳，避免误藏未知入口。
        // 未读到已配置 App 时也保留恢复意图，支持登录启动中该 App 晚于 Ermi 出现。
        let restoreCollapse = collapseRequested
        needsRefresh = true
        generation += 1
        invalidateScan()
        applications = []
        tray.close()
        if collapsed || busy { expand() }
        if restoreCollapse { prepareCollapse(openingTray: false, requestPermissionIfNeeded: false) }
    }

    private func scheduleCollapse() {
        guard enabled, delay > 0 else { return }
        timer = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.delay))
            while !Task.isCancelled {
                // 鼠标仍在菜单栏或正在按键/拖动时延后，避免操作中突然收起。
                let point = NSEvent.mouseLocation
                let inBar = NSScreen.screens.contains { screen in
                    point.x >= screen.frame.minX && point.x <= screen.frame.maxX && point.y >= screen.visibleFrame.maxY && point.y <= screen.frame.maxY
                }
                if !inBar && !self.tray.containsMouse && NSEvent.pressedMouseButtons == 0 && NSEvent.modifierFlags.isEmpty {
                    if self.tray.isPresented { self.dismissTray() }
                    else { self.collapse(requestPermissionIfNeeded: false) }
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func removeItems() {
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        if let separator { NSStatusBar.system.removeStatusItem(separator) }
        toggleItem = nil
        preparationIndicator = nil
        separator = nil
    }
    private func invalidateScan() {
        scanRevision += 1
        needsRefresh = true
        scanTask?.cancel()
        scanTask = nil
        refreshing = false
    }

    func stop() {
        invalidateScan()
        tray.close()
        expand()
        removeItems()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        started = false
    }
}
