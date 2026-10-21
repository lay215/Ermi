import AppKit
import SwiftUI
@preconcurrency import ApplicationServices
import ErmiCore
import ErmiMenuBarBridge

@MainActor
enum Diagnostics {
    // 子页面预览仅限截图进程，不持久化或影响用户平时打开的页面。
    static func previewOption(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard args.contains("--capture-preview"), let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    // 导出与菜单栏共用的 SwiftUI 视图，便于无鼠标验证真实采样和布局。
    static func run(model: MonitorModel) async {
        if let index = CommandLine.arguments.firstIndex(of: "--menu-entry-report") {
            // 只读诊断必须在采样、收纳和风扇启动前结束；不请求授权，也不执行任何 AX 动作。
            if CommandLine.arguments.indices.contains(index + 2) {
                writeMenuEntryReport(bundleID: CommandLine.arguments[index + 1], path: CommandLine.arguments[index + 2])
            }
            finish()
            return
        }
        // 截图语言只影响当前诊断进程，不覆盖用户保存的界面语言。
        if let index = CommandLine.arguments.firstIndex(of: "--preview-language"), CommandLine.arguments.indices.contains(index + 1) {
            AppLocalization.shared.previewLanguage = AppLanguage(rawValue: CommandLine.arguments[index + 1])
        }
        // 预览主题不写入偏好，避免视觉验收覆盖用户选择。
        if let index = CommandLine.arguments.firstIndex(of: "--preview-theme"), CommandLine.arguments.indices.contains(index + 1) {
            ErmiAppearance.shared.previewPreset = ErmiAppearancePreset(rawValue: CommandLine.arguments[index + 1])
        }
        // 系统材质的深浅色与 Ermi 配色独立；只在截图进程覆盖外观，不改系统或用户偏好。
        if let appearance = previewOption("--preview-appearance"), ["light", "dark"].contains(appearance) {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if CommandLine.arguments.contains("--fan-control-check") {
            await checkFanControl()
            finish()
            return
        }
        if CommandLine.arguments.contains("--fan-service-status") {
            // 仅探测身份和只读 inspect，不注册服务，也不应用或恢复风扇预设。
            let client = FanControlClient(onTiming: { timing in
                timing.log()
                print("FAN timing \(timing.summary)")
            })
            // request 内部完成本轮授权检查；诊断与正常轮询一致，不预先重复完整验签。
            do {
                let reply = try await client.request(.inspect)
                print("FAN connected=true phase=\(reply.status.phase.rawValue) capabilities=\(reply.capabilities.count) error=\(reply.error ?? "none")")
                if let message = reply.status.message { print("FAN control-message=\(message)") }
            } catch { print("FAN connected=false error=\(error.localizedDescription)") }
            print("FAN local-mode=\(client.usesLocalMode) installed=\(LocalFanAuthorization.exists) authorized-build=\(client.ready)")
            print(client.localSetupMessage)
            client.disconnect()
            finish()
            return
        }
        if CommandLine.arguments.contains("--icon-smoke-test") {
            await checkIconOrganizer()
            finish()
            return
        }
        let previewsIconTray = CommandLine.arguments.contains("--capture-preview") && CommandLine.arguments.contains("--preview-icon-tray")
        model.designPreview = CommandLine.arguments.contains("--design-reference")
        if model.designPreview {
            model.fanMode = .auto
            if let index = CommandLine.arguments.firstIndex(of: "--fan-mode"), CommandLine.arguments.indices.contains(index + 1),
               let mode = FanMode(rawValue: Int(CommandLine.arguments[index + 1]) ?? -1) { model.fanMode = mode }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--detail-page"), CommandLine.arguments.indices.contains(index + 1),
           let page = DetailPage(rawValue: CommandLine.arguments[index + 1]) { model.detailPage = page }
        // 图标条截图只读取内存样本，不额外采样系统数据，避免预览入口启动无关工作。
        if (!model.designPreview && !previewsIconTray) || CommandLine.arguments.contains("--smoke-test") {
            let sampler = SystemSampler()
            _ = await sampler.sample()
            try? await Task.sleep(for: .seconds(2))
            let snapshot = await sampler.sample()
            model.snapshot = snapshot
            if CommandLine.arguments.contains("--smoke-test") {
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } catch { fputs("\(error)\n", stderr) }
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-preview"), CommandLine.arguments.indices.contains(index + 1) {
            let detailed = !previewsIconTray && CommandLine.arguments.contains("--detail-page")
            let chrome = detailed && CommandLine.arguments.contains("--include-chrome")
            // 列表视觉检查复用注入扫描，隔离偏好且不启动收纳服务，不改变本机图标或授权。
            let fixtureSuite = "app.ermi.preview." + UUID().uuidString
            var previewOrganizer: MenuBarOrganizer?
            if !previewsIconTray && model.designPreview && CommandLine.arguments.contains("--preview-icon-list"),
               let defaults = UserDefaults(suiteName: fixtureSuite) {
                defaults.set(true, forKey: "icons.enabled")
                defaults.set(["com.apple.Notes", "com.apple.Maps"], forKey: "icons.folded")
                defaults.set(["com.apple.finder"], forKey: "icons.hidden")
                // 排序预览只注入临时偏好，不投递系统拖动事件，也不写入用户真实顺序。
                if CommandLine.arguments.contains("--preview-icon-order") {
                    defaults.set(["com.apple.mail", "com.apple.Safari", "com.apple.Notes", "com.apple.Maps", "com.apple.finder"],
                                 forKey: "icons.order")
                }
                let fixture = MenuBarOrganizer(defaults: defaults, permissionCheck: { true }, scanOverride: {
                    ([
                        MenuBarApplication(id: "com.apple.Safari", name: "Safari", count: 2),
                        MenuBarApplication(id: "com.apple.mail", name: "Mail", count: 1),
                        MenuBarApplication(id: "com.apple.Notes", name: "Notes", count: 1),
                        MenuBarApplication(id: "com.apple.Maps", name: "Maps", count: 1),
                        MenuBarApplication(id: "com.apple.finder", name: "Finder", count: 1)
                    ], [:])
                })
                await fixture.refresh()
                previewOrganizer = fixture
            }
            defer { UserDefaults.standard.removePersistentDomain(forName: fixtureSuite) }
            let trayPreview = previewsIconTray ? await makeIconTrayPreview(state: previewOption("--tray-state")) : nil
            let root: AnyView
            if let trayPreview {
                // 导出正式单行视图，只有数据来自样本；不启动面板、AX 扫描或菜单栏隐藏。
                root = AnyView(MenuBarTrayView(tray: trayPreview.tray, width: trayPreview.frame.width))
            } else {
                root = chrome ? AnyView(ErmiWindowContent(model: model, previewOrganizer: previewOrganizer)) : AnyView(MonitorView(model: model, detailed: detailed, openDetails: {}, previewDialog: CommandLine.arguments.contains("--show-process-dialog")))
            }
            let view = NSHostingView(rootView: root)
            // 所有详情页按同一窗口导出，便于与 Tab 设计对照；窄窗口参数仅影响诊断布局。
            view.frame = trayPreview?.frame ?? (detailed ? NSRect(x: 0, y: 0, width: 600, height: 430 - (chrome ? 0 : 35)) : NSRect(x: 0, y: 0, width: ErmiTheme.panelWidth, height: ErmiTheme.panelHeight))
            let window = NSWindow(contentRect: view.frame, styleMask: chrome ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless], backing: .buffered, defer: false)
            if previewsIconTray {
                window.isOpaque = false
                window.backgroundColor = .clear
            }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentView = view
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(500))
            if chrome && CommandLine.arguments.contains("--check-window-chrome") {
                // 显示与缩放会触发 AppKit 再布局，离屏截图无法覆盖这个回归。
                window.makeKeyAndOrderFront(nil)
                for width in [720.0, 600.0] {
                    window.setContentSize(NSSize(width: width, height: 430))
                    window.layoutIfNeeded()
                    view.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(200))
                    func titlebar(in node: NSView) -> ErmiWindowTitlebar.TitlebarView? {
                        if let bar = node as? ErmiWindowTitlebar.TitlebarView { return bar }
                        return node.subviews.lazy.compactMap { titlebar(in: $0) }.first
                    }
                    let buttons = titlebar(in: view)?.buttons ?? []
                    let aligned = buttons.count == 3 && buttons.enumerated().allSatisfy { index, button in
                        guard let parent = button.superview else { return false }
                        return abs(button.frame.midY - parent.bounds.midY) < 0.5
                            && abs(button.frame.minX - CGFloat(18 + index * 20)) < 0.5
                    }
                    print("CHROME width=\(width) aligned=\(aligned)")
                    if !aligned { fputs("Window button alignment failed\n", stderr); exit(1) }
                }
            }
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
            }
            if let trayPreview, CommandLine.arguments.contains("--show-icon-tray-preview") {
                // 系统玻璃依赖 WindowServer 合成，离屏 PNG 只用于布局；显式预览真实面板并自动关闭。
                trayPreview.tray.show(anchor: nil)
                try? await Task.sleep(for: .seconds(30))
                trayPreview.tray.close(clearEntries: false)
            }
            if let trayPreview, CommandLine.arguments.contains("--check-icon-tray-window") {
                // 使用样本入口验证真实 NSPanel 生命周期；不创建隐藏断言、不触发任何第三方菜单。
                let tray = trayPreview.tray
                let entryIDs = tray.entries.map(\.id)
                var dismissals = 0
                tray.onDismiss = { dismissals += 1 }
                let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
                let anchor = NSRect(x: screen.maxX - 80, y: screen.maxY, width: 24, height: 24)
                tray.show(anchor: anchor)
                try? await Task.sleep(for: .milliseconds(150))
                precondition(tray.isPresented && NSApp.keyWindow is ErmiStatusPanel)
                NSApp.keyWindow?.cancelOperation(nil)
                precondition(!tray.isPresented && dismissals == 1)
                tray.show(anchor: anchor)
                try? await Task.sleep(for: .milliseconds(150))
                precondition(tray.isPresented && tray.entries.map(\.id) == entryIDs)
                tray.dismissFromUser()
                precondition(!tray.isPresented && dismissals == 2)
                tray.show(anchor: anchor)
                tray.close()
                precondition(!tray.isPresented && tray.entries.isEmpty && dismissals == 2)
                print("ICON TRAY window-open-escape-reopen-close=passed")
            }
        }
        finish()
    }

    private static func makeIconTrayPreview(state: String?) async -> (tray: MenuBarTray, frame: NSRect) {
        let authorized = state != "permission"
        let iconMode = previewOption("--tray-icons") ?? "status"
        let applications = [
            ("com.apple.Safari", "Safari", "safari"),
            ("com.apple.mail", "Mail", "envelope"),
            ("com.apple.Notes", "Notes", "note.text"),
            ("com.apple.Maps", "Maps", "map"),
            ("com.apple.finder", "Finder", "folder"),
            ("com.apple.Safari", "Safari", "safari")
        ]
        let count = state == "empty" || !authorized ? 0 : (state == "overflow" ? 36 : 6)
        // 无效 PID 只构造 AX 类型占位，不读取任何实际 App；所有扫描和点击均替换为内存实现。
        let element = AXUIElementCreateApplication(-1)
        let entries = (0..<count).map { index in
            let app = applications[index % applications.count]
            // 模板只是视觉样本，不宣称是这些 App 的真实状态图标；fallback 走正式灰度 App 占位。
            var icon = iconMode == "fallback" || (iconMode == "mixed" && index.isMultiple(of: 2))
                ? nil : NSImage(systemSymbolName: app.2, accessibilityDescription: app.1)
            if iconMode == "wide", index == 0 {
                icon = NSImage(size: NSSize(width: 96, height: 18), flipped: false) { _ in
                    NSAttributedString(string: "42% · 63°", attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                        .foregroundColor: NSColor.labelColor
                    ]).draw(at: NSPoint(x: 2, y: 0))
                    return true
                }
            }
            return MenuBarTrayEntry(
                pid: -1, bundleID: app.0, name: app.1, label: "菜单栏入口 · \(index + 1)",
                element: element, action: kAXPressAction,
                frame: CGRect(x: CGFloat(index * 24), y: 0, width: 24, height: 24), icon: icon
            )
        }
        let tray = MenuBarTray(
            permissionCheck: { authorized }, permissionRequest: { authorized }, identityCheck: { _, _ in false },
            scanOverride: { (entries, [:]) }, actionOverride: { _, _ in AXError.notImplemented.rawValue },
            screenCapturePermissionCheck: { iconMode != "fallback" }, screenCapturePermissionRequest: { false }
        )
        await tray.prepare(scope: .applications(Set(entries.map(\.bundleID))))
        // 窄屏样本沿用正式宽度钳制，验证大量入口保持横向一行，不另写预览排版。
        let screen = NSRect(x: 0, y: 0, width: state == "overflow" ? 436 : 800, height: 600)
        let frame = MenuBarTray.layout(anchor: nil, screen: screen, visible: screen,
                                       entryCount: entries.count, showsMessage: entries.isEmpty || !authorized,
                                       showsIconPermission: iconMode == "fallback",
                                       entriesWidth: tray.entries.reduce(0) { $0 + $1.buttonWidth + 4 })
        return (tray, NSRect(origin: .zero, size: frame.size))
    }

    private static func checkFanControl() async {
        let client = FanControlClient()
        try? await client.refreshAvailability()
        let device = SMCFanDevice()
        guard client.ready else { print("FAN CHECK blocked=当前构建尚未授权"); return }
        var reachedTarget = false
        var attemptedApply = false
        do {
            let initial = try await client.request(.inspect)
            // 诊断只在没有既有接管时运行；不替换用户正在应用的预设。
            guard initial.error == nil, initial.status.phase == .system || initial.status.phase == .failed else {
                print("FAN CHECK blocked=已有控制或恢复任务 \(initial.error ?? initial.status.phase.rawValue)")
                client.disconnect(); return
            }
            attemptedApply = true
            let applied = try await client.request(.apply(FanPreset(name: "诊断 4000 RPM", configuration: .fixed(rpm: 4000))))
            print("FAN CHECK apply=\(applied.status.phase.rawValue) message=\(applied.error ?? applied.status.message ?? "none")")
            if applied.error == nil, applied.status.phase == .applied {
                // 每两秒续租并读真实硬件，最多观察八秒；机械响应未达到也不能声称验收通过。
                for sample in 0..<5 {
                    if sample > 0 { try await Task.sleep(for: .seconds(2)) }
                    let heartbeat = try await client.request(.heartbeat)
                    let snapshot = try await device.snapshot()
                    print("FAN CHECK sample=\(sample) \(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))")
                    guard heartbeat.error == nil, heartbeat.status.phase == .applied else {
                        print("FAN CHECK interrupted=\(heartbeat.error ?? heartbeat.status.message ?? heartbeat.status.phase.rawValue)")
                        reachedTarget = false; break
                    }
                    reachedTarget = snapshot.fans.count == 2 && snapshot.fans.allSatisfy {
                        guard let target = $0.targetRPM, let actual = $0.actualRPM else { return false }
                        return $0.mode == .manual && abs(target - 4000) <= 1 && abs(actual - 4000) <= 200
                    }
                }
            }
        } catch { print("FAN CHECK error=\(error)") }
        // 所有已尝试应用的出口都恢复；失败或超时还由断连和 helper 租约兜底，结果必须回读。
        if attemptedApply {
            do {
                let restored = try await client.request(.restore)
                let snapshot = try await device.snapshot()
                let confirmed = restored.error == nil && restored.status.phase == .system && snapshot.fans.count == 2 && snapshot.fans.allSatisfy { $0.mode == .system }
                print("FAN CHECK reached-target=\(reachedTarget) restored=\(confirmed) message=\(restored.error ?? restored.status.message ?? "none")")
            } catch { print("FAN CHECK restore-unconfirmed=\(error)") }
        }
        client.disconnect()
    }

    private static func writeMenuEntryReport(bundleID: String, path: String) {
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let displays = NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        let reports: [[String: Any]] = apps.map { app in
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.3)
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(root, "AXExtrasMenuBar" as CFString, &raw)
            var items: [AXUIElement] = []
            if status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                items = attribute(unsafeBitCast(raw, to: AXUIElement.self), kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
            let managed = MenuBarEntryFilter.managedItems(items, bundleID: bundleID)
            let entries: [[String: Any]] = items.enumerated().map { index, item in
                AXUIElementSetMessagingTimeout(item, 0.3)
                var row: [String: Any] = ["index": index,
                    "includedInOrganizer": managed.contains { CFEqual($0, item) },
                    "sameElementAs": items.indices.filter { $0 < index && CFEqual(items[$0], item) }]
                // 不导出菜单内容或 VPN 配置名；身份、动作和坐标足以区分真实入口、重复引用及屏幕副本。
                for key in [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute] {
                    if let value = attribute(item, key) as? String { row[key] = value }
                }
                var actions: CFArray?
                if AXUIElementCopyActionNames(item, &actions) == .success { row["actions"] = actions as? [String] ?? [] }
                var point = CGPoint.zero, size = CGSize.zero
                if let position = attribute(item, kAXPositionAttribute), let extent = attribute(item, kAXSizeAttribute),
                   CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
                   AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                   AXValueGetValue(unsafeBitCast(extent, to: AXValue.self), .cgSize, &size) {
                    row["frame"] = ["x": point.x, "y": point.y, "width": size.width, "height": size.height]
                    let midpoint = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
                    row["displays"] = displays.filter { CGDisplayBounds($0).contains(midpoint) }
                }
                return row
            }
            return ["pid": app.processIdentifier, "bundleID": bundleID, "extrasStatus": status.rawValue,
                    "entryCount": items.count, "managedEntryCount": managed.count, "entries": entries]
        }
        let report: [String: Any] = ["authorized": AXIsProcessTrusted(), "applications": reports,
            "displayCount": displays.count]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { fputs("Menu entry report failed: \(error)\n", stderr) }
    }

    private static func finish() {
        // 先离开当前 Swift 并发任务，再进入 AppKit 退出流程，允许异步退出确认正常回调。
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private static func checkIconOrganizer() async {
        // 独立配置验证启停和持久化，不修改用户当前分组；原生接口探针保留所有运行 App。
        let name = "app.ermi.diagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let organizer = MenuBarOrganizer(defaults: defaults)
        precondition(!organizer.enabled && !organizer.collapsed && organizer.delay == 0)
        organizer.start()
        organizer.setEnabled(true, requestPermissionIfNeeded: false)
        precondition(organizer.enabled && !organizer.collapsed)
        organizer.setDelay(10)
        let restored = MenuBarOrganizer(defaults: defaults)
        precondition(restored.enabled && restored.delay == 10 && !restored.collapsed)
        organizer.expand()
        organizer.setEnabled(false)
        organizer.stop()
        precondition(!organizer.enabled && !organizer.busy && !organizer.collapsed)
        print("ICON lifecycle-and-preferences=passed native=\(organizer.native) available=\(organizer.available) accessibility=\(organizer.authorized)")
        // 复现系统弹窗返回后授权变化：不点击刷新也必须更新，撤销时清空旧列表。
        var granted = false
        let permissionOrganizer = MenuBarOrganizer(defaults: defaults, permissionCheck: { granted })
        precondition(!permissionOrganizer.authorized)
        granted = true
        await permissionOrganizer.synchronizePermission()
        precondition(permissionOrganizer.authorized)
        granted = false
        await permissionOrganizer.synchronizePermission()
        precondition(!permissionOrganizer.authorized && permissionOrganizer.applications.isEmpty)
        print("ICON permission-grant-and-revoke-refresh=passed")
        if organizer.native && organizer.available {
            let all = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)).union([Bundle.main.bundleIdentifier ?? "app.ermi.local"])
            // 探针不扣除任何 App，只检查断言能否创建和释放，不验证真实隐藏效果。
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                ErmiVisibilityActivate(all.sorted()) { handle, error in
                    if let handle {
                        ErmiVisibilityRelease(handle)
                        print("ICON native-assertion-create-and-release=passed")
                    } else {
                        print("ICON native-assertion=failed \(error?.localizedDescription ?? "unknown")")
                    }
                    continuation.resume()
                }
            }
        }
    }
}
