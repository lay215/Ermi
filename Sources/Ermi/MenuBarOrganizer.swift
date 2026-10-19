import AppKit
@preconcurrency import ApplicationServices
import Observation
import ErmiMenuBarBridge
import ErmiCore

struct MenuBarApplication: Identifiable, Sendable {
    let id: String
    let name: String
    let count: Int
}

@MainActor @Observable
final class MenuBarOrganizer: NSObject {
    private(set) var enabled: Bool
    private(set) var collapsed = false
    private(set) var busy = false
    private(set) var refreshing = false
    private(set) var authorized: Bool
    private(set) var applications: [MenuBarApplication] = []
    private(set) var folded: Set<String>
    private(set) var delay: Int
    var message = ""
    let native = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    var available: Bool { !native || ErmiVisibilityAvailable() }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let permissionCheck: () -> Bool
    @ObservationIgnored private let permissionRequest: () -> Bool
    @ObservationIgnored private var needsRefresh = true
    @ObservationIgnored private let scanOverride: (@Sendable () async -> ([MenuBarApplication], [Int: Int]))?
    @ObservationIgnored private var toggleItem: NSStatusItem?
    @ObservationIgnored private var separator: NSStatusItem?
    @ObservationIgnored private var handle: Any?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var activationTimeout: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var scanRevision = 0
    @ObservationIgnored private var scanTask: Task<([MenuBarApplication], [Int: Int]), Never>?
    @ObservationIgnored private let tray = MenuBarTray()
    // macOS 自身的控件无法按 App 安全拆分，始终保持可见。
    private static let systemOwners = MenuBarVisibilityPlan.systemOwners

    init(
        defaults: UserDefaults = .standard,
        permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        permissionRequest: @escaping () -> Bool = { MenuBarOrganizer.requestSystemPermission() },
        scanOverride: (@Sendable () async -> ([MenuBarApplication], [Int: Int]))? = nil
    ) {
        self.defaults = defaults
        self.permissionCheck = permissionCheck
        self.permissionRequest = permissionRequest
        self.scanOverride = scanOverride
        authorized = permissionCheck()
        enabled = defaults.bool(forKey: "icons.enabled")
        folded = Set(defaults.stringArray(forKey: "icons.folded") ?? [])
        let saved = defaults.integer(forKey: "icons.delay")
        delay = [0, 5, 10, 30, 60].contains(saved) ? saved : 0
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // 新 App 出现时先解除限制，避免白名单把尚未分组的入口意外隐藏。
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appsChanged), name: name, object: nil)
        }
        if enabled { installItems() }
        // 每次启动先展开，让用户能检查分组；仅保存偏好，不恢复隐藏断言。
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
        } else { removeItems() }
    }

    func setDelay(_ value: Int) {
        guard [0, 5, 10, 30, 60].contains(value) else { return }
        delay = value
        defaults.set(value, forKey: "icons.delay")
        timer?.cancel()
        // 改设置不会立即隐藏图标；下次用户展开后才开始计时。
    }

    func setFolded(_ id: String, _ value: Bool) {
        guard applications.contains(where: { $0.id == id }) else { return }
        expand()
        if value { folded.insert(id) } else { folded.remove(id) }
        defaults.set(folded.sorted(), forKey: "icons.folded")
    }

    func requestPermission() {
        // 即使系统立即返回已授权，列表也需要重新读取；不能只比较授权布尔值。
        authorized = permissionRequest()
        needsRefresh = true
        message = authorized ? "权限已识别，正在准备刷新图标。" : "请在系统设置中允许当前 Ermi，返回后自动刷新图标。"
    }

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
        // 系统授权弹窗异步返回；页面可见期间同步变化，避免授权后按钮仍被旧状态禁用。
        // 权限未变化时不刷新列表，防止轮询不断解除用户的收纳状态。
        guard permissionCheck() != authorized || needsRefresh else { return }
        await refresh()
    }

    func refresh() async {
        // 新请求替换旧扫描；关闭功能、退出或 App 集合变化后，旧 AX 结果不能回填。
        invalidateScan()
        let request = scanRevision
        needsRefresh = false
        expand()
        authorized = permissionCheck()
        guard authorized else { applications = []; message = "Ermi 尚未获得\(permissionName)权限。系统中已允许时，请退出并重新打开当前 Ermi。"; return }
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
                guard let items = children as? [AXUIElement], !items.isEmpty else { return nil }
                return MenuBarApplication(id: id, name: name, count: items.count)
            }
            return (found, errors)
        }
        scanTask = scan
        let result = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
        guard request == scanRevision, !Task.isCancelled else { return }
        // 授权可能在后台读取期间撤销，完成时重新核实，不展示曾经有权限读到的旧入口。
        authorized = permissionCheck()
        guard authorized else {
            applications = []
            message = "权限已撤销，请重新授权后刷新图标列表。"
            return
        }
        applications = result.0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // 区分“权限已识别但接口读取失败”与尚未授权，不再把所有空列表归因于权限。
        if applications.isEmpty {
            let failures = result.1.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "、")
            message = "权限已识别，已检查 \(apps.count) 个运行 App，但未读到菜单栏入口。"
                + (failures.isEmpty ? "" : " 系统读取结果：\(failures)。")
        } else {
            message = "已读取 \(applications.count) 个 App。分组更改后保持展开，点击收起应用。"
        }
    }

    func collapse(requestPermissionIfNeeded: Bool = true) {
        guard enabled, available, !busy, !refreshing, !collapsed else { return }
        tray.close()
        timer?.cancel()
        if !native {
            guard arrangementValid else { message = "请按住 ⌘，将分隔线拖到收起箭头左侧，再重试。"; return }
            separator?.length = hiddenLength
            collapsed = true
            updateButton()
            return
        }
        authorized = permissionCheck()
        guard authorized else {
            if requestPermissionIfNeeded { requestPermission() }
            return
        }
        // 白名单从当前全部运行 App 构建；只扣除用户明确选择且本次读取到的入口。
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard let own = Bundle.main.bundleIdentifier else { message = "请从构建后的 Ermi.app 启动图标整理。"; return }
        let plan = MenuBarVisibilityPlan(selected: folded, discovered: Set(applications.map(\.id)), running: running, own: own)
        guard !plan.hidden.isEmpty else { message = "请先将至少一个正在运行的 App 设为折叠收纳。"; return }
        generation += 1
        let request = generation
        busy = true
        // 私有接口可能不回调；超时解除等待，迟到的成功仍由 generation 校验释放。
        activationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, request == self.generation else { return }
            self.expand()
            self.message = "系统响应超时，已取消收起请求。"
        }
        ErmiVisibilityActivate(plan.allowed.sorted()) { [weak self] newHandle, error in
            MainActor.assumeIsolated {
                guard let self, request == self.generation else {
                    // 用户可能在异步完成前点击展开或退出；过期结果必须立即释放。
                    if let newHandle { ErmiVisibilityRelease(newHandle) }
                    return
                }
                self.busy = false
                self.activationTimeout?.cancel()
                if let newHandle {
                    self.handle = newHandle
                    self.collapsed = true
                    self.message = "已收起 \(plan.hidden.count) 个 App 的菜单栏入口。"
                } else {
                    self.message = "收起失败，图标保持显示：\(error?.localizedDescription ?? "系统未接受请求")"
                }
                self.updateButton()
            }
        }
    }

    func expand(automaticallyCollapse: Bool = false) {
        generation += 1
        busy = false
        timer?.cancel()
        activationTimeout?.cancel()
        if let handle { ErmiVisibilityRelease(handle); self.handle = nil }
        separator?.length = 20
        collapsed = false
        updateButton()
        if automaticallyCollapse { scheduleCollapse() }
    }

    func showTray() {
        authorized = permissionCheck()
        guard authorized else { requestPermission(); return }
        // 先释放隐藏断言，使真实 AX 菜单可以响应；展开栏本身不依赖菜单栏可见宽度。
        expand()
        tray.show(anchor: toggleItem?.button?.window?.frame)
    }

    @objc private func toggle() {
        if NSEvent.modifierFlags.contains(.option) { showTray(); return }
        if collapsed || busy { expand(automaticallyCollapse: true) } else { collapse() }
    }

    private func installItems() {
        guard toggleItem == nil, available else { return }
        let item = NSStatusBar.system.statusItem(withLength: 24)
        item.autosaveName = "ErmiIconToggle"
        item.behavior = []
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(toggle)
        toggleItem = item
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
        toggleItem?.button?.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right", accessibilityDescription: collapsed ? "展开收纳图标" : "收起收纳图标")
        toggleItem?.button?.toolTip = collapsed ? "Ermi · 点击展开图标；⌥ 点击打开展开栏" : "Ermi · 点击收起图标；⌥ 点击打开展开栏"
    }

    private var hiddenLength: CGFloat { min(10_000, max(500, (NSScreen.screens.map { $0.frame.width }.max() ?? 2000) * 2)) }
    private var arrangementValid: Bool {
        guard let divider = separator?.button?.window?.frame, let toggle = toggleItem?.button?.window?.frame else { return false }
        return divider.midX < toggle.midX
    }
    @objc private func displayChanged() { tray.close(); expand() }
    @objc func appsChanged() {
        // 任意 App 启停都会改变真实入口；可见页下一次同步重扫，不能永久留下空列表。
        needsRefresh = true
        invalidateScan()
        applications = []
        tray.close()
        if collapsed || busy { expand(); message = "运行 App 已变化，已展开全部图标；可刷新列表后再次收起。" }
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
                if !inBar && NSEvent.pressedMouseButtons == 0 && NSEvent.modifierFlags.isEmpty {
                    self.collapse(requestPermissionIfNeeded: false); return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func removeItems() {
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        if let separator { NSStatusBar.system.removeStatusItem(separator) }
        toggleItem = nil
        separator = nil
    }
    private func invalidateScan() {
        scanRevision += 1
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
