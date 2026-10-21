import AppKit
import SwiftUI
@preconcurrency import ApplicationServices
import Observation
import ErmiCore

enum MenuBarTrayScope: Equatable, Sendable {
    case applications(Set<String>)
    case leftOf(CGFloat)

    func includes(_ entry: MenuBarTrayEntry) -> Bool {
        switch self {
        case .applications(let bundleIDs):
            return bundleIDs.contains(entry.bundleID)
        case .leftOf(let boundary):
            // 旧系统的分组以真实分隔线为界；读不到位置的入口不能猜测属于收纳区。
            guard let frame = entry.frame, frame.minX.isFinite, frame.maxX.isFinite,
                  frame.width > 0, frame.height > 0, boundary.isFinite else { return false }
            return frame.maxX <= boundary
        }
    }
}

// AX 引用只在后台顺序读取/执行；保留精确元素，绝不按刷新后的下标误点其他入口。
struct MenuBarTrayEntry: Identifiable, @unchecked Sendable {
    let id = UUID()
    let pid: pid_t
    let bundleID: String
    let name: String
    let label: String
    let element: AXUIElement
    let action: String?
    var frame: CGRect? = nil
    // 仅保存原状态项图像（或诊断模板）；App 图标是视图层独立的灰度占位，不能冒充原图标。
    var icon: NSImage? = nil
    var fallbackIcon: NSImage? = nil
    var orderingID: String { MenuBarEntryIdentity.shared.id(pid: pid, bundleID: bundleID, element: element) }

    var displayIcon: NSImage? {
        guard let icon, icon.size.width.isFinite, icon.size.height.isFinite,
              icon.size.width > 0, icon.size.height > 0,
              icon.size.width / icon.size.height * 18 <= 120 else { return nil }
        return icon
    }
    // 保留状态数字的比例与 18pt 高度；过长的整段状态文字回退 App 图标，避免压成不可读细线。
    var iconWidth: CGFloat { displayIcon.map { max(20, $0.size.width / $0.size.height * 18) } ?? 20 }
    var buttonWidth: CGFloat { max(32, iconWidth + 12) }
}

@MainActor @Observable
final class MenuBarTray: NSObject, NSWindowDelegate {
    // 单行 18pt 图标放在 28pt 点击区内，上下各留 4pt；窗口与 SwiftUI 共用高度，避免透明空边。
    static let rowHeight: CGFloat = 36
    static let buttonHeight: CGFloat = 28
    private(set) var entries: [MenuBarTrayEntry] = []
    private(set) var message = ""
    private(set) var loading = false
    private(set) var authorized: Bool
    private(set) var screenCaptureAuthorized: Bool
    private(set) var isPresented = false
    var onDismiss: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onMoveApplication: ((String, String?) -> Bool)?
    var onMoveEntry: ((String, String?) -> Bool)?
    var beforeActivate: ((MenuBarTrayEntry) async -> Bool)?
    var afterActivate: ((MenuBarTrayEntry) -> Void)?
    @ObservationIgnored private let permissionCheck: () -> Bool
    @ObservationIgnored private let permissionRequest: () -> Bool
    @ObservationIgnored private let screenCapturePermissionCheck: () -> Bool
    @ObservationIgnored private let screenCapturePermissionRequest: () -> Bool
    @ObservationIgnored private let iconCaptureOverride: (([MenuBarTrayEntry]) async -> [UUID: NSImage])?
    @ObservationIgnored private let identityCheck: (pid_t, String) -> Bool
    @ObservationIgnored private let scanOverride: (@Sendable () async -> ([MenuBarTrayEntry], [Int: Int]))?
    @ObservationIgnored private let actionOverride: (@Sendable (MenuBarTrayEntry, String) async -> Int32)?
    @ObservationIgnored private var panel: ErmiStatusPanel?
    @ObservationIgnored private var anchor: NSRect?
    @ObservationIgnored private var scope: MenuBarTrayScope?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var scanTask: Task<([MenuBarTrayEntry], [Int: Int]), Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var globalClickMonitor: Any?
    @ObservationIgnored private var localEventMonitor: Any?
    @ObservationIgnored private var diagnostic = ""
    @ObservationIgnored private var applicationOrder: [String] = []
    @ObservationIgnored private var entryOrder: [String] = []
    private(set) var panelWidth: CGFloat = 240
    private(set) var failed = false

    init(
        permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        permissionRequest: @escaping () -> Bool = { MenuBarOrganizer.requestSystemPermission() },
        identityCheck: @escaping (pid_t, String) -> Bool = { pid, bundle in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return app.bundleIdentifier == bundle && app.bundleURL?.pathExtension == "app"
        },
        scanOverride: (@Sendable () async -> ([MenuBarTrayEntry], [Int: Int]))? = nil,
        actionOverride: (@Sendable (MenuBarTrayEntry, String) async -> Int32)? = nil,
        screenCapturePermissionCheck: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        screenCapturePermissionRequest: @escaping () -> Bool = { MenuBarTray.requestScreenCapturePermission() },
        iconCaptureOverride: (([MenuBarTrayEntry]) async -> [UUID: NSImage])? = nil
    ) {
        self.permissionCheck = permissionCheck
        self.permissionRequest = permissionRequest
        self.identityCheck = identityCheck
        self.scanOverride = scanOverride
        self.actionOverride = actionOverride
        self.screenCapturePermissionCheck = screenCapturePermissionCheck
        self.screenCapturePermissionRequest = screenCapturePermissionRequest
        self.iconCaptureOverride = iconCaptureOverride
        authorized = permissionCheck()
        screenCaptureAuthorized = screenCapturePermissionCheck()
        super.init()
    }

    var containsMouse: Bool {
        isPresented && panel?.frame.contains(NSEvent.mouseLocation) == true
    }

    var messageHelp: String {
        diagnostic.isEmpty ? L(message) : "\(L(message)) \(diagnostic)"
    }

    func setApplicationOrder(_ order: [String]) {
        // 只重排同一份快照，保留每个入口的 UUID、AX 引用及图像，拖动后点击仍执行原来的精确元素。
        var seen = Set<String>()
        applicationOrder = order.filter { !$0.isEmpty && seen.insert($0).inserted }
        entries = ordered(entries)
        resizePresentedPanel()
    }

    func setEntryOrder(_ order: [String]) {
        var seen = Set<String>()
        entryOrder = order.filter { seen.insert($0).inserted }
        entries = ordered(entries)
        resizePresentedPanel()
    }

    @discardableResult
    func moveEntry(_ id: String, before target: String?) -> Bool {
        guard isPresented, authorized, !loading, permissionCheck(), id != target,
              entries.contains(where: { $0.orderingID == id }) else { return false }
        if let target, !entries.contains(where: { $0.orderingID == target }) { return false }
        return onMoveEntry?(id, target) ?? false
    }

    @discardableResult
    func moveApplication(_ id: String, before target: String?) -> Bool {
        guard isPresented, authorized, !loading, permissionCheck(),
              entries.contains(where: { $0.bundleID == id }), id != target else { return false }
        if let target, !entries.contains(where: { $0.bundleID == target }) { return false }
        return onMoveApplication?(id, target) ?? false
    }

    private func ordered(_ values: [MenuBarTrayEntry]) -> [MenuBarTrayEntry] {
        let ranks = Dictionary(uniqueKeysWithValues: applicationOrder.enumerated().map { ($0.element, $0.offset) })
        let entryRanks = Dictionary(uniqueKeysWithValues: entryOrder.enumerated().map { ($0.element, $0.offset) })
        return values.enumerated().sorted { lhs, rhs in
            // 逐入口偏好优先，重排仅改变数组位置，不替换 UUID、动作或 AX 元素。
            let leftEntry = entryRanks[lhs.element.orderingID] ?? Int.max
            let rightEntry = entryRanks[rhs.element.orderingID] ?? Int.max
            if leftEntry != rightEntry { return leftEntry < rightEntry }
            let left = ranks[lhs.element.bundleID] ?? Int.max
            let right = ranks[rhs.element.bundleID] ?? Int.max
            if left != right { return left < right }
            // 同 App 多入口沿用实际左右位置；没有自定义顺序时，整条横栏保持原来的位置排序。
            if Self.precedes(lhs.element, rhs.element) { return true }
            if Self.precedes(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    func prepare(scope: MenuBarTrayScope) async {
        // 在主菜单栏收纳之前采集真实入口；后续打开小栏只使用这份分组快照。
        revision += 1
        let request = revision
        scanTask?.cancel()
        self.scope = scope
        loading = false
        failed = false
        diagnostic = ""
        entries = []
        authorized = permissionCheck()
        guard authorized else {
            message = "请先在图标整理页授予辅助功能 / 设备控制和数据访问权限。"
            resizePresentedPanel()
            return
        }
        loading = true
        defer {
            if request == revision { loading = false; resizePresentedPanel() }
        }
        message = "读取真实菜单栏入口…"
        resizePresentedPanel()
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String, String)? in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleIdentifier, app.bundleURL?.pathExtension == "app",
                  !MenuBarVisibilityPlan.systemOwners.contains(bundle) else { return nil }
            // 应用分组仅扫描已选 App；分隔线分组需要读位置后再决定归属。
            if case .applications(let ids) = scope, !ids.contains(bundle) { return nil }
            return (app.processIdentifier, bundle, app.localizedName ?? bundle)
        }
        let scanOverride = self.scanOverride
        let scan = Task.detached(priority: .userInitiated) {
            if let scanOverride { return await scanOverride() }
            return Self.scan(apps)
        }
        scanTask = scan
        // detached 不自动继承取消；显式传播，关闭后不再扫描其余 App。
        let result = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
        guard request == revision else { return }
        scanTask = nil
        guard !Task.isCancelled else {
            entries = []
            message = "此分组暂无可展开的菜单栏入口。"
            resizePresentedPanel()
            return
        }
        authorized = permissionCheck()
        guard authorized else {
            entries = []
            message = "权限已撤销，请重新授权后刷新。"
            resizePresentedPanel()
            return
        }
        var preparedEntries = result.0.filter { scope.includes($0) }.sorted(by: Self.precedes)
        screenCaptureAuthorized = screenCapturePermissionCheck()
        if screenCaptureAuthorized, !preparedEntries.isEmpty {
            // 收纳前缓存原图像，点击与再次打开只读缓存；取图不释放隐藏断言，也不自动请求录屏授权。
            // 诊断扫描自带模板图像；只有显式注入的采集器才会在样本模式继续采集。
            let images: [UUID: NSImage]
            if let iconCaptureOverride { images = await iconCaptureOverride(preparedEntries) }
            else if scanOverride == nil { images = await MenuBarIconCapture.capture(preparedEntries) }
            else { images = [:] }
            for index in preparedEntries.indices {
                if let image = images[preparedEntries[index].id] { preparedEntries[index].icon = image }
            }
        }
        guard request == revision, !Task.isCancelled else { return }
        authorized = permissionCheck()
        guard authorized else {
            entries = []
            message = "权限已撤销，请重新授权后刷新。"
            return
        }
        screenCaptureAuthorized = screenCapturePermissionCheck()
        // 录屏撤权只撤回图片；AX 分组与原菜单点击仍可继续使用。
        if !screenCaptureAuthorized {
            for index in preparedEntries.indices { preparedEntries[index].icon = nil }
        }
        var fallbackByApp: [String: NSImage] = [:]
        for index in preparedEntries.indices {
            let entry = preparedEntries[index]
            if fallbackByApp[entry.bundleID] == nil {
                let original = NSRunningApplication(processIdentifier: entry.pid)?.icon
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID)
                        .map { NSWorkspace.shared.icon(forFile: $0.path) }
                fallbackByApp[entry.bundleID] = original.flatMap(Self.grayscaleIcon)
                    ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            }
            preparedEntries[index].fallbackIcon = fallbackByApp[entry.bundleID]
        }
        entries = ordered(preparedEntries)
        failed = entries.isEmpty && !result.1.isEmpty
        message = failed ? "读取菜单栏入口失败，请刷新。" : (entries.isEmpty ? "此分组暂无可展开的菜单栏入口。" : "")
        diagnostic = result.1.sorted { $0.key < $1.key }.map { "AX \($0.key)×\($0.value)" }.joined(separator: "、")
        resizePresentedPanel()
    }

    func show(anchor: NSRect?) {
        self.anchor = anchor
        synchronizeIconPermission()
        // 撤权后立即清掉已缓存的 AX 引用；显示本身不会重新扫描全部菜单栏。
        authorized = permissionCheck()
        if !authorized {
            entries = []
            message = "权限已撤销，请重新授权后刷新。"
        }
        if panel == nil {
            let window = ErmiStatusPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: Self.rowHeight),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.level = .popUpMenu
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window.delegate = self
            window.onDismiss = { [weak self] in self?.dismissFromUser() }
            window.contentView = NSHostingView(rootView: MenuBarTrayView(tray: self))
            panel = window
        }
        isPresented = true
        resizePresentedPanel()
        installEventMonitors()
        panel?.makeKeyAndOrderFront(nil)
    }

    func close(clearEntries: Bool = true) {
        // 程序主动收起不触发 onDismiss，避免 organizer 的关闭回调再次展开或收纳。
        revision += 1
        scanTask?.cancel()
        scanTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        loading = false
        if clearEntries { entries = [] }
        isPresented = false
        panel?.orderOut(nil)
        removeEventMonitors()
    }

    func removeTerminatedEntries(running: Set<String>, terminatedPID: pid_t?) {
        // 只移除退出进程的精确缓存；同 bundle 的其他进程仍可保留，其他 App 的 UUID/AX/图像不重建。
        entries.removeAll { !running.contains($0.bundleID) || $0.pid == terminatedPID }
        if entries.isEmpty {
            failed = false
            diagnostic = ""
            message = "此分组暂无可展开的菜单栏入口。"
        }
        // 不增加 revision：仍在执行的其他 App 动作应正常完成；已退出入口的迟到结果由成员检查拒绝。
        resizePresentedPanel()
    }

    func dismissFromUser() {
        guard isPresented else { return }
        close(clearEntries: false)
        onDismiss?()
    }

    func windowWillClose(_ notification: Notification) {
        dismissFromUser()
    }

    func refresh() {
        guard let scope else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.prepare(scope: scope) }
    }

    func requestPermission() {
        authorized = permissionRequest()
        if authorized {
            if let onRefresh { onRefresh() } else { refresh() }
        }
    }

    func refreshFromUser() {
        guard permissionCheck() else { requestPermission(); return }
        // 收纳状态下先由 organizer 恢复真实入口，再重新采集同一分组。
        if let onRefresh { onRefresh() } else { refresh() }
    }

    func synchronizePermission() {
        synchronizeIconPermission()
        guard isPresented, permissionCheck() != authorized else { return }
        // 撤权只清理缓存并显示授权状态；重新授权后的采集交回 organizer，确保先恢复真实入口。
        if !permissionCheck() {
            revision += 1
            scanTask?.cancel()
            scanTask = nil
            entries = []
            loading = false
            authorized = false
            message = "权限已撤销，请重新授权后刷新。"
            resizePresentedPanel()
        } else {
            authorized = true
            refreshFromUser()
        }
    }

    func synchronizeIconPermission() {
        let granted = screenCapturePermissionCheck()
        guard granted != screenCaptureAuthorized else { return }
        screenCaptureAuthorized = granted
        if !granted {
            for index in entries.indices { entries[index].icon = nil }
        }
        // 返回授权页时不自动展开菜单栏取图，下次用户主动收纳时更新快照。
        resizePresentedPanel()
    }

    func requestOriginalIconsPermission() {
        _ = screenCapturePermissionRequest()
        synchronizeIconPermission()
    }

    static func requestScreenCapturePermission() -> Bool {
        let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return granted
    }

    static func grayscaleIcon(_ original: NSImage) -> NSImage? {
        // 生成真正的灰度位图；仅用 SwiftUI saturation 滤镜时，部分 AppKit 合成/导出路径仍显示原色。
        var proposed = CGRect(x: 0, y: 0, width: 36, height: 36)
        guard let source = original.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let scale = 36 / CGFloat(max(source.width, source.height))
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let gray = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            // 只转换预乘 RGB，保留原 alpha，避免色彩空间转换把透明边缘变成黑底。
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let red = Int(base[offset])
                let green = Int(base[offset + 1])
                let blue = Int(base[offset + 2])
                let luminance: Int = (54 * red + 183 * green + 19 * blue + 128) / 256
                let gray = UInt8(luminance)
                base[offset] = gray
                base[offset + 1] = gray
                base[offset + 2] = gray
            }
            return context.makeImage()
        }
        return gray.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)) }
    }

    func activate(_ entry: MenuBarTrayEntry) async {
        guard !loading, entries.contains(where: { $0.id == entry.id }), let action = entry.action else { return }
        guard permissionCheck() else {
            authorized = false
            entries = []
            message = "权限已撤销，请重新授权后刷新。"
            resizePresentedPanel()
            return
        }
        loading = true
        let request = revision
        defer { if request == revision { loading = false; resizePresentedPanel() } }
        // organizer 仅校验当前收纳状态；始终对隐藏前缓存的同一个 AX 元素发送原动作。
        if let beforeActivate, !(await beforeActivate(entry)) {
            // 准备期间可能撤权或退出目标 App；只更新本次请求，避免覆盖随后打开的新分组。
            guard request == revision, !Task.isCancelled else { return }
            authorized = permissionCheck()
            if !authorized { entries = [] }
            if !authorized || !identityCheck(entry.pid, entry.bundleID) {
                failed = true
                message = "入口已失效或权限不可用，请刷新。"
            }
            return
        }
        guard request == revision, !Task.isCancelled, entries.contains(where: { $0.id == entry.id }) else { return }
        authorized = permissionCheck()
        guard authorized, identityCheck(entry.pid, entry.bundleID) else {
            if !authorized { entries = [] }
            failed = true
            message = "入口已失效或权限不可用，请刷新。"
            return
        }
        let actionOverride = self.actionOverride
        // 不启动 App、不合成坐标点击；只调用所选元素明确支持的单次 AX 操作。
        let status = await Task.detached(priority: .userInitiated) {
            if let actionOverride { return await actionOverride(entry, action) }
            return AXUIElementPerformAction(entry.element, action as CFString).rawValue
        }.value
        guard request == revision, !Task.isCancelled, entries.contains(where: { $0.id == entry.id }) else { return }
        if status == AXError.success.rawValue {
            close(clearEntries: false)
            afterActivate?(entry)
        } else {
            // 超时也可能已打开菜单，绝不自动重试或换动作，避免重复点击关闭真实菜单。
            failed = true
            message = "未确认打开，请检查菜单后重试。"
            diagnostic = "\(entry.name) · AX \(status)"
        }
    }

    static func layout(anchor: NSRect?, screen: NSRect, visible: NSRect, entryCount: Int, showsMessage: Bool,
                       showsIconPermission: Bool = false, entriesWidth: CGFloat? = nil) -> NSRect {
        // 整排按数量自适应；窄屏保留横向滚动，且左右、底部都不越过当前屏幕。
        let naturalWidth = showsMessage ? CGFloat(300) : (entriesWidth ?? CGFloat(max(entryCount, 1)) * 36) + 52 + (showsIconPermission ? 28 : 0)
        let width = min(max(naturalWidth, 88), max(screen.width - 16, 1))
        let height = min(rowHeight, visible.height)
        let x = min(max((anchor?.maxX ?? visible.maxX) - width, screen.minX + 8), screen.maxX - width - 8)
        let top = min(anchor?.minY ?? visible.maxY, visible.maxY) - 6
        let y = max(visible.minY, top - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func shouldDismiss(at point: NSPoint, panelFrame: NSRect?, anchor: NSRect?) -> Bool {
        // 锚点属于切换按钮的点击区域，不能被当作外部点击先关闭一次。
        panelFrame?.contains(point) != true && anchor?.contains(point) != true
    }

    private func resizePresentedPanel() {
        guard isPresented, let panel else { return }
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        let frame = Self.layout(anchor: anchor, screen: screen.frame, visible: screen.visibleFrame,
                                entryCount: entries.count, showsMessage: entries.isEmpty || failed || !authorized,
                                showsIconPermission: !screenCaptureAuthorized,
                                entriesWidth: entries.reduce(0) { $0 + $1.buttonWidth + 4 }
                                    + (onMoveEntry == nil ? 0 : 16))
        panelWidth = frame.width
        panel.setFrame(frame, display: true)
    }

    private func installEventMonitors() {
        removeEventMonitors()
        // 状态项自身的点击留给 toggle 处理；若提前关闭，会在 mouseUp 再次误展开。
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissForOutsideClick(at: NSEvent.mouseLocation) }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isPresented else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismissFromUser(); return true }
                } else if event.window !== self.panel {
                    self.dismissForOutsideClick(at: NSEvent.mouseLocation)
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    private func dismissForOutsideClick(at point: NSPoint) {
        guard isPresented, Self.shouldDismiss(at: point, panelFrame: panel?.frame, anchor: anchor) else { return }
        dismissFromUser()
    }

    private func removeEventMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        globalClickMonitor = nil
        localEventMonitor = nil
    }

    nonisolated private static func precedes(_ lhs: MenuBarTrayEntry, _ rhs: MenuBarTrayEntry) -> Bool {
        // 与真实菜单栏的左右位置一致；无法读取位置的应用入口稳定排在末尾。
        switch (lhs.frame, rhs.frame) {
        case let (left?, right?) where left.minX != right.minX: return left.minX < right.minX
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            let names = lhs.name.localizedStandardCompare(rhs.name)
            return names == .orderedSame ? lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending : names == .orderedAscending
        }
    }

    nonisolated private static func scan(_ apps: [(pid_t, String, String)]) -> ([MenuBarTrayEntry], [Int: Int]) {
        var found: [MenuBarTrayEntry] = []
        var errors: [Int: Int] = [:]
        for (pid, bundle, name) in apps {
            guard !Task.isCancelled else { break }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.15)
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &raw)
            guard status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                if status != .success { errors[Int(status.rawValue), default: 0] += 1 }
                continue
            }
            let bar = unsafeDowncast(raw, to: AXUIElement.self)
            var children: CFTypeRef?
            let childStatus = AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children)
            guard childStatus == .success, let rawItems = children as? [AXUIElement] else {
                if childStatus != .success { errors[Int(childStatus.rawValue), default: 0] += 1 }
                continue
            }
            let items = MenuBarEntryFilter.managedItems(rawItems, bundleID: bundle)
            for (index, item) in items.enumerated() {
                guard !Task.isCancelled else { break }
                AXUIElementSetMessagingTimeout(item, 0.15)
                var title = ""
                for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(item, key as CFString, &value) == .success,
                       let text = value as? String, !text.isEmpty { title = text; break }
                }
                var rawActions: CFArray?
                AXUIElementCopyActionNames(item, &rawActions)
                let actions = rawActions as? [String] ?? []
                let action = actions.contains(kAXPressAction) ? kAXPressAction : (actions.contains(kAXShowMenuAction) ? kAXShowMenuAction : nil)
                // 同一 App 多入口逐项保留；无 AX 标题时明确编号，不伪造菜单名称。
                let label = items.count > 1 ? "\(title.isEmpty ? "菜单栏入口" : title) · \(index + 1)/\(items.count)" : (title.isEmpty ? "菜单栏入口" : title)
                found.append(MenuBarTrayEntry(pid: pid, bundleID: bundle, name: name, label: label,
                                              element: item, action: action, frame: readFrame(item)))
            }
        }
        return (found, errors)
    }

    nonisolated private static func readFrame(_ item: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeDowncast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeDowncast(rawSize, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}

struct MenuBarTrayView: View {
    @Bindable var tray: MenuBarTray
    var width: CGFloat? = nil
    @State private var targetedApp: String?
    @State private var targetedEnd = false

    var body: some View {
        HStack(spacing: 4) {
            if !tray.authorized {
                Image(systemName: "lock").foregroundStyle(.secondary)
                Button(L("前往授权")) { tray.requestPermission() }
                    .buttonStyle(.link).font(.system(size: 12))
                Spacer(minLength: 0)
            } else if tray.entries.isEmpty {
                if tray.loading { ProgressView().controlSize(.small) }
                Text(L(tray.message)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).help(tray.messageHelp)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(tray.entries) { entry in
                            if tray.onMoveEntry != nil && !tray.loading {
                                MenuBarTrayButton(tray: tray, entry: entry)
                                    .draggable(entry.orderingID)
                                    .overlay(alignment: .leading) {
                                        if targetedApp == entry.orderingID {
                                            Rectangle().fill(.tint).frame(width: 2, height: 20)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .dropDestination(for: String.self) { ids, _ in
                                        guard ids.count == 1, let id = ids.first else { return false }
                                        return tray.moveEntry(id, before: entry.orderingID)
                                    } isTargeted: { targeted in
                                        if targeted { targetedApp = entry.orderingID }
                                        else if targetedApp == entry.orderingID { targetedApp = nil }
                                    }
                            } else {
                                MenuBarTrayButton(tray: tray, entry: entry)
                            }
                        }
                        if tray.onMoveEntry != nil && !tray.loading {
                            // 末尾单独提供落点，不嵌套到图标目标中，避免一次拖放既插入又追加。
                            Color.clear.frame(width: 12, height: MenuBarTray.buttonHeight)
                                .contentShape(Rectangle())
                                .overlay {
                                    if targetedEnd { Rectangle().fill(.tint).frame(width: 2, height: 20) }
                                }
                                .dropDestination(for: String.self) { ids, _ in
                                    guard ids.count == 1, let id = ids.first else { return false }
                                    return tray.moveEntry(id, before: nil)
                                } isTargeted: { targetedEnd = $0 }
                                .help(L("拖到此处排在最后"))
                        }
                    }
                }.scrollIndicators(.hidden)
                if tray.loading {
                    ProgressView().controlSize(.small).frame(width: 16)
                } else if tray.failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary).help(tray.messageHelp)
                        .accessibilityLabel(L(tray.message))
                }
            }
            Divider().frame(height: 18).padding(.horizontal, 2).accessibilityHidden(true)
            if tray.authorized && (tray.entries.isEmpty || tray.failed) && !tray.loading {
                Button { tray.refreshFromUser() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: MenuBarTray.buttonHeight)
                }
                .buttonStyle(MenuBarTrayButtonStyle()).foregroundStyle(.secondary)
                .help(L("刷新")).accessibilityLabel(L("刷新"))
            }
            if tray.authorized && !tray.entries.isEmpty && !tray.screenCaptureAuthorized {
                Button { tray.requestOriginalIconsPermission() } label: {
                    Image(systemName: "photo").frame(width: 24, height: MenuBarTray.buttonHeight)
                }
                .buttonStyle(MenuBarTrayButtonStyle()).foregroundStyle(.secondary)
                .help(L("允许屏幕录制以显示原图标；授权后下次收纳生效。"))
                .accessibilityLabel(L("授权菜单栏原图标"))
            }
            Button { tray.dismissFromUser() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: MenuBarTray.buttonHeight)
            }
            .buttonStyle(MenuBarTrayButtonStyle()).foregroundStyle(.secondary)
            .help(L("关闭")).accessibilityLabel(L("关闭"))
        }
        .padding(.horizontal, 8).frame(width: width ?? tray.panelWidth, height: MenuBarTray.rowHeight)
        // 展开栏跟随 macOS 外观与辅助显示设置，不再套用主界面的固定浅色纸面和蓝色墨迹。
        .foregroundStyle(.primary)
        .modifier(MenuBarTraySurface())
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                tray.synchronizePermission()
            }
        }
    }
}

private struct MenuBarTraySurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        // 新系统使用原生 Liquid Glass；旧系统使用菜单浮层材质，窗口阴影仍由 NSPanel 绘制。
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            content.background {
                MenuBarTrayPopoverMaterial()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct MenuBarTrayPopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        // 面板不激活第三方 App；材质保持活跃，并模糊窗口后方桌面而非透明窗口自身。
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct MenuBarTrayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isEnabled ? (configuration.isPressed ? 0.16 : (hovering ? 0.08 : 0)) : 0))
            }
            .onHover { hovering = $0 }
    }
}

private struct MenuBarTrayButton: View {
    @Bindable var tray: MenuBarTray
    let entry: MenuBarTrayEntry

    private var title: String {
        // AX 无标题的编号入口仍沿用翻译词条，真实 App 返回的标题则保持原文。
        let label = entry.label == "菜单栏入口" || entry.label.hasPrefix("菜单栏入口 · ")
            ? entry.label.replacingOccurrences(of: "菜单栏入口", with: L("菜单栏入口")) : entry.label
        return "\(entry.name) · \(label)" + (entry.action == nil ? " · \(L("不支持"))" : "")
    }

    var body: some View {
        Button { Task { await tray.activate(entry) } } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon = entry.displayIcon {
                        // 原状态项的透明轮廓使用系统前景色，随系统深浅色切换，不残留原图的白色或彩色像素。
                        Image(nsImage: icon).renderingMode(.template).resizable().scaledToFit()
                    } else {
                        // 缺少录屏授权或窗口不可捕捉时保持可辨认的 App 形状，但移除彩色视觉噪声。
                        Image(nsImage: entry.fallbackIcon
                              ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage())
                            .renderingMode(.original).resizable().scaledToFit()
                    }
                }
                .frame(width: entry.iconWidth, height: 18).opacity(entry.action == nil ? 0.5 : 1)
                if entry.action == nil {
                    Image(systemName: "nosign").font(.system(size: 9, weight: .bold))
                        .background(.regularMaterial, in: Circle()).offset(x: 3, y: 3)
                }
            }
            .frame(width: entry.buttonWidth, height: MenuBarTray.buttonHeight)
        }
        .buttonStyle(MenuBarTrayButtonStyle()).disabled(tray.loading || entry.action == nil)
        .help(title).accessibilityLabel(title)
    }
}
