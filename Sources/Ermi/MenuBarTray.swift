import AppKit
import SwiftUI
@preconcurrency import ApplicationServices
import Observation
import ErmiCore

// AX 引用只在后台顺序读取/执行，不跨线程修改；保留精确元素，绝不按刷新后的下标误点其他入口。
struct MenuBarTrayEntry: Identifiable, @unchecked Sendable {
    let id = UUID()
    let pid: pid_t
    let bundleID: String
    let name: String
    let label: String
    let element: AXUIElement
    let action: String?
}

@MainActor @Observable
final class MenuBarTray: NSObject, NSWindowDelegate {
    var entries: [MenuBarTrayEntry] = []
    var message = ""
    var loading = false
    var authorized = AXIsProcessTrusted()
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func show(anchor: NSRect?) {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            window.title = L("Ermi · 菜单栏展开栏")
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: MenuBarTrayView(tray: self))
            panel = window
        }
        if let panel {
            let screen = NSScreen.screens.first { $0.frame.contains(anchor?.origin ?? NSEvent.mouseLocation) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let x = min(max((anchor?.maxX ?? visible.maxX) - panel.frame.width, visible.minX), visible.maxX - panel.frame.width)
                panel.setFrameOrigin(NSPoint(x: x, y: visible.maxY - panel.frame.height - 8))
            }
            panel.title = L("Ermi · 菜单栏展开栏")
            panel.makeKeyAndOrderFront(nil)
        }
        refresh()
    }

    func close() {
        revision += 1
        task?.cancel()
        loading = false
        entries = []
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 标题栏关闭也必须废弃在途扫描和 AX 引用，与应用主动关闭保持一致。
        close()
    }

    func refresh() {
        // 撤权也使在途扫描失效，避免旧结果把无权限页面重新填满。
        revision += 1
        task?.cancel()
        loading = false
        authorized = AXIsProcessTrusted()
        guard authorized else {
            entries = []
            message = "请先在图标整理页授予辅助功能 / 设备控制和数据访问权限。"
            return
        }
        let request = revision
        loading = true
        message = "读取真实菜单栏入口…"
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String, String)? in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleIdentifier, app.bundleURL?.pathExtension == "app",
                  !MenuBarVisibilityPlan.systemOwners.contains(bundle) else { return nil }
            return (app.processIdentifier, bundle, app.localizedName ?? bundle)
        }
        task?.cancel()
        task = Task { [weak self] in
            let scan = Task.detached(priority: .userInitiated) {
                var found: [MenuBarTrayEntry] = []
                var errors: [Int32: Int] = [:]
                for (pid, bundle, name) in apps {
                    guard !Task.isCancelled else { break }
                    let application = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(application, 0.15)
                    var raw: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &raw)
                    guard status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                        errors[status.rawValue, default: 0] += 1; continue
                    }
                    let bar = unsafeDowncast(raw, to: AXUIElement.self)
                    var children: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
                          let items = children as? [AXUIElement] else { continue }
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
                        found.append(MenuBarTrayEntry(pid: pid, bundleID: bundle, name: name, label: label, element: item, action: action))
                    }
                }
                return (found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, errors)
            }
            // detached 不自动继承取消；显式传播，关闭后不再扫描其余 App。
            let result = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard let self, request == self.revision, !Task.isCancelled else { return }
            self.authorized = AXIsProcessTrusted()
            guard self.authorized else {
                self.entries = []
                self.loading = false
                self.message = "权限已撤销，请重新授权后刷新。"
                return
            }
            self.entries = result.0
            self.loading = false
            self.message = result.0.isEmpty
                ? "未读到入口。AX 返回码：" + result.1.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "、")
                : "点击访问实际菜单栏入口；不支持 AX 操作的入口会标明。"
        }
    }

    func requestPermission() {
        authorized = MenuBarOrganizer.requestSystemPermission()
        if authorized { refresh() }
    }

    func refreshFromUser() {
        guard AXIsProcessTrusted() else { requestPermission(); return }
        refresh()
    }

    func synchronizePermission() {
        // 展开栏独立存在时，也应在用户从系统设置返回后恢复真实入口。
        guard panel?.isVisible == true, AXIsProcessTrusted() != authorized else { return }
        refresh()
    }

    func activate(_ entry: MenuBarTrayEntry) {
        guard AXIsProcessTrusted() else { requestPermission(); return }
        guard !loading, AXIsProcessTrusted(), let action = entry.action,
              NSRunningApplication(processIdentifier: entry.pid)?.bundleIdentifier == entry.bundleID else {
            message = "入口已失效或权限不可用，请刷新。"; return
        }
        loading = true
        let request = revision
        // 不启动 App、不合成坐标点击、不请求屏幕录制；仅调用用户选择元素公开支持的 AX 操作。
        task = Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                AXUIElementPerformAction(entry.element, action as CFString).rawValue
            }.value
            guard let self, request == self.revision else { return }
            self.loading = false
            if status == AXError.success.rawValue {
                self.close()
            } else {
                // 超时可能已产生副作用，不能自动重试或切换另一动作，否则可能把刚打开的菜单关掉。
                self.message = "\(entry.name) 未确认打开（AX \(status)）。请检查菜单；不会自动重试。"
            }
        }
    }
}

private struct MenuBarTrayView: View {
    @Bindable var tray: MenuBarTray
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("菜单栏入口")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("刷新")) { tray.refreshFromUser() }.disabled(tray.loading)
            }
            if !tray.authorized {
                Button(L("前往授权")) { tray.requestPermission() }
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(tray.entries) { entry in
                        Button { tray.activate(entry) } label: {
                            HStack(spacing: 9) {
                                Image(nsImage: NSRunningApplication(processIdentifier: entry.pid)?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage())
                                    .resizable().scaledToFit().frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.system(size: 11, weight: .medium))
                                    Text(entry.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(L(entry.action == nil ? "不支持" : "打开")).font(.system(size: 10))
                            }.padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(tray.loading || entry.action == nil)
                    }
                }
            }
            Text(L(tray.message)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(width: 360, height: 260).background(ErmiTheme.paper).foregroundStyle(ErmiTheme.ink).tint(ErmiTheme.link)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                tray.synchronizePermission()
            }
        }
    }
}
