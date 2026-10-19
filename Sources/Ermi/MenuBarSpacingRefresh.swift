import AppKit
import Observation

@MainActor
struct SpacingRefreshTarget: Identifiable {
    let id: String
    let name: String
    let restart: () async -> String?
}

/// 保存与重启分开：确认清单固定后才执行，期间新出现的 App 不会被顺带退出。
@MainActor @Observable
final class MenuBarSpacingRefresh {
    private(set) var busy = false
    private(set) var message = ""

    func clearMessage() {
        guard !busy else { return }
        message = ""
    }

    func apply(targets: [SpacingRefreshTarget], save: () -> Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard save() else { message = "保存失败，未重启任何 App。"; return }
        var failures: [String] = []
        var completed = 0
        for target in targets {
            message = "正在刷新 \(target.name)…"
            if let error = await target.restart() { failures.append("\(target.name)：\(error)") }
            else { completed += 1 }
        }
        message = "已保存，已刷新 \(completed) 项。"
        if !failures.isEmpty { message += " 未完成：" + failures.joined(separator: "；") + "。" }
        message += "未识别的图标及 Ermi 自身需下次启动后应用；若仍无变化，请注销重新登录。"
    }

    static func plan(applications: [MenuBarApplication]) -> [SpacingRefreshTarget] {
        var targets: [SpacingRefreshTarget] = []
        let ids = Set(applications.map(\.id))
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, ids.contains(id),
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !id.hasPrefix("com.apple."), let url = app.bundleURL,
                  url.pathExtension == "app", !url.path.contains("/Contents/") else { continue }
            let name = app.localizedName ?? id
            targets.append(SpacingRefreshTarget(id: "\(app.processIdentifier)", name: name) {
                // 保留扫描时的进程对象与路径，不按同名进程杀进程，也不切换到另一份安装。
                guard !app.isTerminated else { return "原进程已退出，请手动重新打开" }
                guard app.terminate() else { return "拒绝退出，已保留运行" }
                for _ in 0..<100 {
                    if app.isTerminated { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard app.isTerminated else { return "尚未退出，已保留运行；请处理保存窗口" }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.addsToRecentItems = false
                do {
                    let reopened = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                    return reopened.isTerminated ? "重新打开失败，请手动打开" : nil
                } catch { return "重新打开失败：\(error.localizedDescription)" }
            })
        }
        // 系统组件由 launchd 管理，不能 terminate 后用 open 启动。只使用本机已核实的两个 job。
        for (file, name) in [("com.apple.controlcenter", "控制中心"), ("com.apple.SystemUIServer", "系统菜单栏")] {
            let url = URL(fileURLWithPath: "/System/Library/LaunchAgents/\(file).plist")
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            targets.append(SpacingRefreshTarget(id: label, name: name) {
                await Task.detached {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    do { try process.run() } catch { return "刷新命令未能启动" }
                    // 限制等待时间；终止的只是 launchctl 客户端，不强制结束第三方 App。
                    for _ in 0..<100 {
                        if !process.isRunning { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if process.isRunning { process.terminate(); return "系统刷新超时" }
                    return process.terminationStatus == 0 ? nil : "系统拒绝刷新，需重新登录"
                }.value
            })
        }
        return targets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
