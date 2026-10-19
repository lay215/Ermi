import SwiftUI
import AppKit

/// 紧凑页面只压缩展示；授权、分组和恢复显示仍交由原菜单栏控制器处理。
struct IconOrganizerView: View {
    @Bindable var organizer: MenuBarOrganizer
    var isActive = true
    @State private var query = ""
    @State private var group = "全部"
    @State private var page = Diagnostics.previewOption("--icons-page") == "spacing" ? "间距与行为" : "图标分组"

    private var foldedCount: Int {
        organizer.applications.filter { organizer.folded.contains($0.id) }.count
    }
    private var filtered: [MenuBarApplication] {
        organizer.applications.filter {
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query))
                && (group == "全部" || (organizer.folded.contains($0.id) == (group == "收起")))
        }
    }
    private var summary: String {
        if !organizer.available { return "当前系统暂不支持收纳" }
        if !organizer.enabled { return "已停用收纳，所有图标均显示" }
        if organizer.native && !organizer.authorized { return "需要\(L(organizer.permissionName))权限" }
        if organizer.busy { return "正在收起图标…" }
        if !organizer.native { return organizer.collapsed ? "收纳区图标已收起" : "菜单栏图标已展开" }
        return organizer.collapsed ? "已收起 \(foldedCount) 个 App 的图标" : "全部已展开 · \(foldedCount) 个 App 待收起"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("图标整理")).font(.system(size: 13, weight: .semibold))
                    Text(L("让常用图标留在菜单栏，其余图标按需展开。"))
                        .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                }
                Spacer(minLength: 12)
                Toggle(L("收纳图标"), isOn: Binding(get: { organizer.enabled }, set: { organizer.setEnabled($0) }))
                    .font(.system(size: 10)).toggleStyle(.switch).controlSize(.mini).tint(ErmiTheme.link)
                    .disabled(!organizer.available)
            }
            ErmiSegmentedControl(options: ["图标分组", "间距与行为"], selection: $page) { $0 }
            // 仅切换展示分区，原收纳状态、授权检查和后台扫描保持同一控制器。
            if page == "图标分组" {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L(summary)).font(.system(size: 10, weight: .medium))
                        Text(L("系统图标与 Ermi 始终保留"))
                            .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    }
                    Spacer(minLength: 8)
                    Button(L(organizer.busy ? "取消收起" : (organizer.collapsed ? "临时展开" : "立即收起"))) {
                        if organizer.busy { organizer.expand() }
                        else if organizer.collapsed { organizer.expand(automaticallyCollapse: true) }
                        else { organizer.collapse() }
                    }.buttonStyle(ErmiDetailButtonStyle())
                        .disabled(!organizer.enabled || organizer.refreshing || !organizer.available)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).detailCard()
                if !organizer.available {
                    note("当前系统的菜单栏接口不可用，图标保持显示。系统更新后可重新检查。", symbol: "exclamationmark.triangle")
                } else if organizer.native {
                    nativeGroups
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("按住 ⌘ 拖动图标分组")).font(.system(size: 10, weight: .medium))
                        Text(L("将分隔线 │ 放到收起箭头左侧，再把需要收纳的图标拖到分隔线左侧。常用图标与 Ermi 留在右侧。"))
                            .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).fixedSize(horizontal: false, vertical: true)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).detailCard()
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("展开后自动收起")).font(.system(size: 10, weight: .medium))
                            Text(L("临时展开后，按设定时间重新收纳图标。"))
                                .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                        }
                        Spacer()
                        DetailMenu(title: "展开后自动收起", selection: Binding(get: { organizer.delay }, set: { organizer.setDelay($0) }), options: [(0, "不自动收起")] + [5, 10, 30, 60].map { ($0, "\($0) 秒后") })
                            .frame(width: 125)
                    }.padding(12)
                    Divider().overlay(ErmiTheme.detailLine)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("展开栏")).font(.system(size: 10, weight: .medium))
                            Text(L("通过独立窗口访问已收起的菜单栏项目。"))
                                .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                        }
                        Spacer()
                        Button(L("打开展开栏 ↗")) { organizer.showTray() }
                            .buttonStyle(ErmiDetailButtonStyle())
                    }.padding(12)
                }.frame(maxWidth: .infinity, alignment: .leading).detailCard()
            }
            // 保留间距编辑状态，切回分组时不丢弃尚未保存的滑条值。
            MenuBarSpacingView(organizer: organizer)
                .frame(height: page == "间距与行为" ? nil : 0)
                .clipped().opacity(page == "间距与行为" ? 1 : 0)
                .disabled(page != "间距与行为").accessibilityHidden(page != "间距与行为")
            if !organizer.message.isEmpty {
                // 错误与真实读取结果在两个分区中均可见，不以布局隐藏故障信息。
                Text(L(organizer.message)).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 使用说明常显，标题与正文保持稳定层级，不再由原生折叠控件改变字号和缩进。
            VStack(alignment: .leading, spacing: 6) {
                Text(L("系统图标与 Ermi 始终保留 · 使用说明"))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(ErmiTheme.detailInk)
                Text(L(organizer.native
                     ? "按 App 分组，同一 App 的多个入口一起显示或收起。依赖系统私有接口，升级后可能失效。停用或退出 Ermi 会恢复显示。"
                     : "位置由 macOS 保存，新图标可能进入收纳区；展开后可重新拖动。刘海遮挡的图标可能仍不可见。停用或退出 Ermi 会恢复显示。"))
                Text(L("自动收起从临时展开后计时。展开栏以真实 App 图标显示菜单栏入口，点击调用该入口；也可 ⌥ 点击菜单栏箭头打开。"))
            }.font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        }
        .foregroundStyle(ErmiTheme.detailInk)
        .buttonStyle(.borderless)
        .task(id: isActive) {
            // Tab 保留视图以维持筛选和滚动位置，但隐藏页不扫描或改变图标展开状态。
            guard isActive, organizer.native else { return }
            await organizer.refresh()
            // 页面可见时检查授权变化；离开后取消，避免后台持续扫描。
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await organizer.synchronizePermission()
            }
        }
    }

    private var nativeGroups: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !organizer.authorized {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("允许读取菜单栏图标"), systemImage: "hand.raised").font(.system(size: 10, weight: .medium))
                    Text(L("在系统设置 → 隐私与安全性 → \(L(organizer.permissionName))中允许 Ermi，返回后自动刷新。"))
                        .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button(L("前往授权")) { organizer.requestPermission() }.buttonStyle(ErmiDetailButtonStyle())
                        refreshButton
                    }.font(.system(size: 9))
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).detailCard()
            } else {
                HStack(spacing: 6) {
                    ErmiSegmentedControl(options: ["全部", "保留", "收起"], selection: $group,
                                         minimumSegmentWidth: 44, fontSize: 9, segmentHeight: 24) { $0 }
                    Spacer(minLength: 6)
                    TextField(L("搜索 App"), text: $query).textFieldStyle(.roundedBorder).frame(width: 120)
                    refreshButton
                }.font(.system(size: 10)).controlSize(.mini)
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            ErmiLogo(size: 18)
                            Text("Ermi").font(.system(size: 10, weight: .medium))
                            Spacer()
                            Text(L("始终显示 · 保留入口")).font(.system(size: 9)).foregroundStyle(ErmiTheme.detailMuted)
                        }.frame(height: 37)
                        ForEach(filtered) { app in
                            Divider().overlay(ErmiTheme.detailLine)
                            HStack(spacing: 8) {
                                Image(nsImage: appIcon(app.id)).resizable().scaledToFit().frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    Text(L("\(app.name) · \(app.count) 个菜单栏入口"))
                                        .font(.system(size: 9)).foregroundStyle(ErmiTheme.detailMuted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                DetailMenu(title: "\(app.name)图标位置", selection: Binding(get: { organizer.folded.contains(app.id) }, set: { organizer.setFolded(app.id, $0) }), options: [(false, "保留"), (true, "收起")])
                                    .frame(width: 90).disabled(!organizer.enabled)
                            }.frame(height: 37)
                        }
                        if filtered.isEmpty {
                            Text(L(organizer.refreshing ? "正在读取本机图标…" : (organizer.applications.isEmpty ? "暂无可管理的菜单栏 App" : "没有符合条件的 App")))
                                .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).padding(.vertical, 10)
                        }
                    }.padding(.horizontal, 10)
                }
                .frame(height: min(190, CGFloat(max(2, filtered.count + 1)) * 38))
                .frame(maxWidth: .infinity, alignment: .leading).detailCard()
            }
        }
    }

    private var refreshButton: some View {
        Button(L(organizer.refreshing ? "读取中…" : "刷新")) { Task { await organizer.refreshFromUser() } }
            .buttonStyle(ErmiDetailButtonStyle()).disabled(organizer.refreshing)
    }
    private func appIcon(_ id: String) -> NSImage {
        // 先取当前运行实例，避免多版本安装时显示另一份 App 的图标；失效时只回退通用图标。
        if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.icon { return icon }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app", accessibilityDescription: L("应用图标")) ?? NSImage()
    }
    private func note(_ text: String, symbol: String) -> some View {
        Label(L(text), systemImage: symbol).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
            .fixedSize(horizontal: false, vertical: true).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ErmiTheme.detailControl, in: RoundedRectangle(cornerRadius: 8))
    }
}
