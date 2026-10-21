import AppKit
import SwiftUI
import ErmiCore

@main
struct ErmiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L("系统设置…")) { delegate.openSettingsPage() }.keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class ErmiStatusPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    private var panel: ErmiStatusPanel!
    let model = MonitorModel()
    private var detail: NSWindow?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusLogo()
        Self.configureTemperatureLayout(item, showTemperature: model.showMenuBarTemperature)
        if model.showMenuBarTemperature { item.button?.toolTip = L("Ermi · 正在读取 CPU 温度") }
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.target = self
        item.button?.action = #selector(toggle)
        if CommandLine.arguments.contains("--menu-entry-report") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--capture-preview") || CommandLine.arguments.contains("--icon-smoke-test") || CommandLine.arguments.contains("--fan-service-status") || CommandLine.arguments.contains("--fan-control-check") {
            Task { await Diagnostics.run(model: model) }
            return
        }
        configurePanel()
        model.iconOrganizer.start()
        model.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            Self.configureTemperatureLayout(self.item, showTemperature: self.model.showMenuBarTemperature,
                                            temperature: snapshot?.hardware.cpuTemperature?.celsius)
        }
        model.start()
        // 睡眠先暂停续租和新操作，再交还控制；唤醒重新连接后尝试恢复最后成功配置。
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.prepareForSleep() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.resumeAfterSleep() }
        }
        if CommandLine.arguments.contains("--show-window") { showDetails() }
        if CommandLine.arguments.contains("--show-icons") { showDetails(.icons) }
        if CommandLine.arguments.contains("--show-panel") { showPanel() }
    }

    static func configureTemperatureLayout(_ item: NSStatusItem, showTemperature: Bool = true, temperature: Double? = nil) {
        guard let button = item.button else { return }
        // 关闭摘要时同步回收文字占位；采样刷新也走此入口，避免下一帧重新显示温度。
        guard showTemperature else {
            button.title = ""
            // 仅 Logo 时用 24pt 宽度容纳 19pt 图像，避免随菜单栏高度增加两侧留白。
            item.length = 24
            button.toolTip = "Ermi"
            return
        }
        // 等宽数字消除 51° / 59° 等同位数读数的字宽差异，保持系统菜单栏字号。
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        // HardwareSensors 只接受 (0, 150]°C；提前容纳三位整数及未知态，
        // 避免跨越 99°、启动或读数丢失时重新挤动相邻入口。两侧各留 6 pt 点击留白。
        button.title = " 150°"
        let temperatureWidth = button.cell?.cellSize.width ?? 0
        button.title = " —°"
        item.length = ceil(max(temperatureWidth, button.cell?.cellSize.width ?? 0)) + 12
        if let temperature {
            button.title = " \(Int(temperature.rounded()))°"
            button.toolTip = String(format: L("Ermi · CPU 温度 %.1f°C"), temperature)
        } else {
            button.toolTip = L("Ermi · 温度暂不可用")
        }
    }

    private func configurePanel() {
        // R4 没有系统气泡箭头与白色衬底，透明 NSPanel 可保留原稿圆角、边框及真实窗口阴影。
        panel = ErmiStatusPanel(contentRect: NSRect(x: 0, y: 0, width: ErmiTheme.panelWidth, height: ErmiTheme.panelHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onDismiss = { [weak self] in self?.hidePanel() }
        // 全局仅观察鼠标点击，不监听键盘；点击其他 App 时收起面板。
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let detail = self.detail, event.window === detail { self.hidePanel() }
            }
            return event
        }
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            if model.iconOrganizer.enabled {
                menu.addItem(withTitle: L("展开全部收纳图标"), action: #selector(expandIcons), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: L("系统设置…"), action: #selector(openSettingsPage), keyEquivalent: ",").target = self
            menu.addItem(withTitle: L("图标整理…"), action: #selector(openIcons), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: L("退出 Ermi"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
            item.menu = menu
            button.performClick(nil)
            item.menu = nil
            return
        }
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    @objc private func expandIcons() { model.iconOrganizer.expand() }
    @objc func openSettingsPage() { showDetails(.settings) }
    @objc private func openIcons() { showDetails(.icons) }

    private func showPanel() {
        guard let button = item.button, let statusWindow = button.window else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = statusWindow.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let height = min(ErmiTheme.panelHeight, max(240, visible.height - 16))
        let x = min(max(anchor.maxX - ErmiTheme.panelWidth, visible.minX + 8), visible.maxX - ErmiTheme.panelWidth - 8)
        let y = max(visible.minY + 8, anchor.minY - height - 8)
        let root = ScrollView(.vertical) {
            MonitorView(model: model, detailed: false, openDetails: { [weak self] in self?.showDetails() }, openPage: { [weak self] page in self?.showDetails(page) })
        }.scrollIndicators(.hidden).frame(width: ErmiTheme.panelWidth, height: height)
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(NSRect(x: x, y: y, width: ErmiTheme.panelWidth, height: height), display: false)
        panel.makeKeyAndOrderFront(nil)
        model.isVisible = true
        model.temperatureSensorPanelVisible = true
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        model.temperatureSensorPanelVisible = false
        model.isVisible = detail?.isVisible == true
    }

    private func showDetails(_ page: DetailPage? = nil) {
        if let page { model.detailPage = page }
        hidePanel()
        if detail == nil {
            // 三页共用固定的初始窗口尺寸；切换 Tab 只更新内容，保留窗口位置和用户缩放结果。
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 430), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Ermi"
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
            window.isOpaque = false
            window.titlebarAppearsTransparent = true
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ErmiWindowContent(model: model))
            window.minSize = NSSize(width: 600, height: 430)
            window.center()
            detail = window
        }
        detail?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.isVisible = true
        model.temperatureSensorDetailVisible = true
    }

    private func statusLogo() -> NSImage {
        // 与主浮层使用同一白鼬取景，保留原图比例而非缩放整张概念板。
        let size = CGFloat(19)
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: size * 0.26, yRadius: size * 0.26).addClip()
            ErmiResources.logo.draw(in: NSRect(x: -size * 0.3868, y: -size * 0.1393, width: size * 2.9966, height: size * 1.584), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
    }

    // SwiftUI 缓存页不会随窗口隐藏而消失，按真实窗口生命周期决定是否额外读取传感器列表。
    func windowDidBecomeKey(_ notification: Notification) {
        model.isVisible = true
        model.temperatureSensorDetailVisible = true
    }
    func windowWillClose(_ notification: Notification) {
        model.isVisible = panel?.isVisible == true
        model.temperatureSensorDetailVisible = false
    }
    func windowDidMiniaturize(_ notification: Notification) {
        model.isVisible = panel?.isVisible == true
        model.temperatureSensorDetailVisible = false
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        model.isVisible = true
        model.temperatureSensorDetailVisible = true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 诊断启动在 model.start 前返回，从未接管风扇；直接退出，避免异步确认嵌套事件循环。
        if CommandLine.arguments.contains("--menu-entry-report") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--capture-preview") || CommandLine.arguments.contains("--icon-smoke-test") || CommandLine.arguments.contains("--fan-service-status") || CommandLine.arguments.contains("--fan-control-check") {
            return .terminateNow
        }
        Task {
            let restored = await model.prepareForExit()
            if restored { sender.reply(toApplicationShouldTerminate: true) }
            else {
                let alert = NSAlert()
                alert.messageText = "尚未确认恢复系统风扇控制"
                alert.informativeText = model.controlNotice + "\n请恢复系统控制后再退出。"
                alert.addButton(withTitle: L("返回 Ermi"))
                alert.runModal()
                model.start()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.iconOrganizer.stop()
        model.stop()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }
}
