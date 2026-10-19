import AppKit
import SwiftUI
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
        // 截图语言只影响当前诊断进程，不覆盖用户保存的界面语言。
        if let index = CommandLine.arguments.firstIndex(of: "--preview-language"), CommandLine.arguments.indices.contains(index + 1) {
            AppLocalization.shared.previewLanguage = AppLanguage(rawValue: CommandLine.arguments[index + 1])
        }
        // 预览主题不写入偏好，避免视觉验收覆盖用户选择。
        if let index = CommandLine.arguments.firstIndex(of: "--preview-theme"), CommandLine.arguments.indices.contains(index + 1) {
            ErmiAppearance.shared.previewPreset = ErmiAppearancePreset(rawValue: CommandLine.arguments[index + 1])
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
        model.designPreview = CommandLine.arguments.contains("--design-reference")
        if model.designPreview {
            model.fanMode = .auto
            if let index = CommandLine.arguments.firstIndex(of: "--fan-mode"), CommandLine.arguments.indices.contains(index + 1),
               let mode = FanMode(rawValue: Int(CommandLine.arguments[index + 1]) ?? -1) { model.fanMode = mode }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--detail-page"), CommandLine.arguments.indices.contains(index + 1),
           let page = DetailPage(rawValue: CommandLine.arguments[index + 1]) { model.detailPage = page }
        if !model.designPreview || CommandLine.arguments.contains("--smoke-test") {
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
            let detailed = CommandLine.arguments.contains("--detail-page")
            let chrome = detailed && CommandLine.arguments.contains("--include-chrome")
            // 列表视觉检查复用注入扫描，隔离偏好且不启动收纳服务，不改变本机图标或授权。
            let fixtureSuite = "app.ermi.preview." + UUID().uuidString
            var previewOrganizer: MenuBarOrganizer?
            if model.designPreview && CommandLine.arguments.contains("--preview-icon-list"),
               let defaults = UserDefaults(suiteName: fixtureSuite) {
                defaults.set(true, forKey: "icons.enabled")
                defaults.set(["preview.docker", "preview.dropbox", "preview.raycast"], forKey: "icons.folded")
                let fixture = MenuBarOrganizer(defaults: defaults, permissionCheck: { true }, scanOverride: {
                    ([
                        MenuBarApplication(id: "preview.wechat", name: "微信", count: 1),
                        MenuBarApplication(id: "preview.lark", name: "Lark", count: 1),
                        MenuBarApplication(id: "preview.docker", name: "Docker", count: 1),
                        MenuBarApplication(id: "preview.dropbox", name: "Dropbox", count: 1),
                        MenuBarApplication(id: "preview.raycast", name: "Raycast", count: 1)
                    ], [:])
                })
                await fixture.refresh()
                previewOrganizer = fixture
            }
            defer { UserDefaults.standard.removePersistentDomain(forName: fixtureSuite) }
            let root = chrome ? AnyView(ErmiWindowContent(model: model, previewOrganizer: previewOrganizer)) : AnyView(MonitorView(model: model, detailed: detailed, openDetails: {}, previewDialog: CommandLine.arguments.contains("--show-process-dialog")))
            let view = NSHostingView(rootView: root)
            // 所有详情页按同一窗口导出，便于与 Tab 设计对照；窄窗口参数仅影响诊断布局。
            view.frame = detailed ? NSRect(x: 0, y: 0, width: 600, height: 430 - (chrome ? 0 : 35)) : NSRect(x: 0, y: 0, width: ErmiTheme.panelWidth, height: ErmiTheme.panelHeight)
            let window = NSWindow(contentRect: view.frame, styleMask: chrome ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless], backing: .buffered, defer: false)
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
        }
        finish()
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
