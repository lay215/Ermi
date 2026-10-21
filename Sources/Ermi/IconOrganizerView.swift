import SwiftUI
import AppKit

/// 正式扫描提供精确入口身份；仅不含 AX 元素的预览样本使用带 preview 前缀的本地身份。
struct MenuBarApplicationIcon: Identifiable {
    let application: MenuBarApplication
    let index: Int
    var id: String { application.entryIDs.indices.contains(index) ? application.entryIDs[index] : "preview:\(application.id):\(index)" }
    var name: String { application.count > 1 ? "\(application.name) \(index + 1)" : application.name }
    static func items(for application: MenuBarApplication) -> [Self] {
        (0..<max(0, application.count)).map { Self(application: application, index: $0) }
    }
}

/// 紧凑页面只压缩展示；授权、分组和恢复显示仍交由原菜单栏控制器处理。
struct IconOrganizerView: View {
    @Bindable var organizer: MenuBarOrganizer
    var isActive = true
    @State private var query = ""
    @State private var selectedID = Diagnostics.previewOption("--selected-icon")
    @State private var hoveredID: String?
    @State private var targetedGroup: MenuBarIconGroup?
    @State private var insertionBeforeID: String?
    @State private var page = Diagnostics.previewOption("--icons-page") == "spacing" ? "间距与行为" : "图标分组"

    private var foldedCount: Int {
        organizer.applications.filter { organizer.group(for: $0.id) == .folded }.count
    }
    private var hiddenCount: Int {
        organizer.applications.filter { organizer.group(for: $0.id) == .hidden }.count
    }
    private var filtered: [MenuBarApplication] {
        organizer.orderedApplications.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
    private var canEditGroups: Bool {
        organizer.enabled && organizer.available && organizer.authorized && !organizer.busy && !organizer.refreshing
    }
    private var allIcons: [MenuBarApplicationIcon] {
        organizer.orderedIcons
    }
    private var selectedIcon: MenuBarApplicationIcon? {
        allIcons.first { $0.id == selectedID || ($0.index == 0 && $0.application.id == selectedID) }
    }
    private var summary: String {
        if !organizer.available { return "当前系统暂不支持收纳" }
        if !organizer.enabled { return "已停用收纳，所有图标均显示" }
        if organizer.native && !organizer.authorized { return "需要\(L(organizer.permissionName))权限" }
        if organizer.sorting { return "正在同步菜单栏顺序…" }
        if organizer.busy { return "正在准备展开栏" }
        if organizer.trayPresented { return "收纳图标已在菜单栏下方展开" }
        if !organizer.native { return organizer.collapsed ? "收纳区图标已收起" : "菜单栏图标已展开" }
        return organizer.collapsed
            ? "已收起 \(foldedCount) 个 App · 已隐藏 \(hiddenCount) 个 App"
            : "待应用 · 收起 \(foldedCount) 个 App · 隐藏 \(hiddenCount) 个 App"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("图标整理")).font(.system(size: 13, weight: .semibold))
                    Text(L(organizer.native
                           ? "保留常用图标，收起次要图标，隐藏不需要的图标。"
                           : "让常用图标留在菜单栏，其余图标按需展开。"))
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
                        Text(L(organizer.native ? "修改分组后立即生效，启动时自动收纳。" : "系统图标与 Ermi 始终保留"))
                            .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    }
                    Spacer(minLength: 8)
                    Button(L(organizer.sorting ? "取消同步" : (organizer.busy ? "取消收起" : (organizer.trayPresented ? "收起展开栏" : (organizer.collapsed ? "临时展开" : "立即收起"))))) {
                        if organizer.busy { organizer.expand() }
                        else if organizer.collapsed || organizer.trayPresented { organizer.showTray() }
                        else { organizer.collapse() }
                    }.buttonStyle(ErmiDetailButtonStyle())
                        // 自动准备清单也属于打开请求，设置页的显式取消在扫描期间仍可用。
                        .disabled(!organizer.enabled || (organizer.refreshing && !organizer.busy) || !organizer.available)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).detailCard()
                if !organizer.available {
                    note("当前系统的菜单栏接口不可用，图标保持显示。系统更新后可重新检查。", symbol: "exclamationmark.triangle")
                } else if organizer.native {
                    nativeGroups
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("按住 ⌘ 拖动图标分组")).font(.system(size: 10, weight: .medium))
                        Text(L("将分隔线 │ 放到展开箭头左侧，再把需要收纳的图标拖到分隔线左侧。常用图标与 Ermi 留在右侧。"))
                            .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).fixedSize(horizontal: false, vertical: true)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).detailCard()
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("展开后自动收起")).font(.system(size: 10, weight: .medium))
                            Text(L("展开栏打开后开始计时；鼠标停在栏内时保持展开。"))
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
                            Text(L("点击菜单栏箭头，展开或收起下方的收纳图标。"))
                                .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                        }
                        Spacer()
                        Button(L("打开展开栏 ↗")) { organizer.showTray() }
                            .buttonStyle(ErmiDetailButtonStyle())
                            .disabled(!organizer.enabled || organizer.busy || organizer.refreshing || !organizer.available)
                    }.padding(12)
                    Divider().overlay(ErmiTheme.detailLine)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("菜单栏原图标")).font(.system(size: 10, weight: .medium))
                            Text(L(organizer.originalIconsAuthorized
                                   ? "已允许读取原图标，下次收纳时更新；读取不到时使用灰度图标。"
                                   : "允许屏幕录制以读取原图标；未允许时使用灰度图标，仍可正常点击。"))
                                .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if !organizer.originalIconsAuthorized {
                            Button(L("授权原图标…")) { organizer.requestOriginalIconsPermission() }
                                .buttonStyle(ErmiDetailButtonStyle())
                        }
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
                     ? "每个入口可独立排序；同一 App 的保留、收起或隐藏仍一起生效。跨组请使用「移动整个 App」按钮。点击「同步菜单栏顺序」让 macOS 保存顶部位置。停用或退出 Ermi 会恢复显示。"
                     : "位置由 macOS 保存，新图标可能进入收纳区；展开后可重新拖动。刘海遮挡的图标可能仍不可见。停用或退出 Ermi 会恢复显示。"))
                Text(L("展开栏仅显示收起组，优先使用单色菜单栏原图标，未获取时使用灰度 App 图标。点击执行原操作，菜单栏保持收纳；点击外部或按 Esc 关闭展开栏。"))
            }.font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        }
        .foregroundStyle(ErmiTheme.detailInk)
        .buttonStyle(.borderless)
        .onChange(of: allIcons.map(\.id)) { _, _ in
            // 刷新后已退出的 App 或减少的入口不再显示移动操作；固定入口不依赖扫描结果。
            if let selectedID, !selectedID.hasPrefix("fixed:"), selectedIcon == nil { self.selectedID = nil }
        }
        .onChange(of: query) { _, _ in
            // 搜索只筛选各组里的 App，清除已被筛掉的选择，避免移动看不见的旧选中项。
            if let selectedIcon, !filtered.contains(where: { $0.id == selectedIcon.application.id }) { selectedID = nil }
        }
        .onChange(of: canEditGroups) { _, allowed in
            // 扫描、同步或撤权中断拖放时，清除旧落点，恢复编辑后不残留插入线。
            if !allowed { targetedGroup = nil; insertionBeforeID = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isActive { organizer.synchronizeIconPermission() }
        }
        .task(id: isActive) {
            // 所有系统均同步图片权限；仅原生分组需要 AX 扫描。隐藏页不改变图标展开状态。
            guard isActive else { return }
            organizer.synchronizeIconPermission()
            // 进入设置页只同步缺失清单和权限，不把已自动收纳的图标重新展开。
            if organizer.native { await organizer.synchronizePermission() }
            // 页面可见时检查授权变化；离开后取消，避免后台持续扫描。
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if organizer.native { await organizer.synchronizePermission() }
                else { organizer.synchronizeIconPermission() }
            }
        }
    }

    private var nativeGroups: some View {
        VStack(alignment: .leading, spacing: 5) {
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
                    Text(L("拖动排序与分组")).font(.system(size: 9, weight: .medium))
                    Spacer(minLength: 6)
                    TextField(L("搜索 App"), text: $query).textFieldStyle(.roundedBorder).frame(width: 120)
                    refreshButton
                    Button(L(organizer.sorting ? "同步中…" : "同步菜单栏顺序")) { organizer.applyMenuBarOrder() }
                        .buttonStyle(ErmiDetailButtonStyle())
                        .disabled(!canEditGroups || (organizer.applicationOrder.isEmpty && organizer.entryOrder.isEmpty) || organizer.applications.isEmpty)
                        .help(L("拖动先保存设置与展开栏顺序；同步后才重排系统菜单栏。"))
                }.font(.system(size: 10)).controlSize(.mini)
                // 三组均保留图标前与组末落点；排序先保存为设置/展开栏顺序，由明确按钮同步到真实菜单栏。
                ForEach(MenuBarIconGroup.allCases, id: \.rawValue) { group in
                    groupRow(group)
                }
                selectionActions
            }
        }
    }

    private func groupRow(_ group: MenuBarIconGroup) -> some View {
        let apps = filtered.filter { organizer.group(for: $0.id) == group }
        let visibleApps = Set(apps.map(\.id))
        let icons = organizer.orderedIcons.filter { visibleApps.contains($0.application.id) }
        let highlighted = targetedGroup == group && canEditGroups
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(L(groupTitle(group))).font(.system(size: 9, weight: .semibold))
                Text("\(icons.count)").font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                Spacer(minLength: 6)
                Text(L(groupDescription(group)))
                    .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
            }.padding(.horizontal, 2)
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        if group == .retained {
                            fixedTile(id: "fixed:ermi", name: "Ermi", symbol: nil)
                            fixedTile(id: "fixed:system", name: "系统图标", symbol: "switch.2")
                            Rectangle().fill(ErmiTheme.detailLine).frame(width: 0.5, height: 24).padding(.horizontal, 2)
                        }
                        ForEach(icons) { icon in sortableTile(icon, in: group) }
                        groupEndTarget(group, isEmpty: apps.isEmpty)
                    }
                    // 内容不足一行时，剩余空白全部归组末落点；超过一行时仍保留末尾的小块落点。
                    .frame(minWidth: max(0, geometry.size.width - 12), alignment: .leading)
                    .padding(.horizontal, 6).frame(height: 42)
                }.scrollIndicators(.hidden)
            }.frame(height: 42)
            .frame(maxWidth: .infinity, alignment: .leading).detailCard()
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(highlighted ? ErmiTheme.link : .clear, lineWidth: 1.5))
            .background(highlighted ? ErmiTheme.link.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    @ViewBuilder
    private func sortableTile(_ icon: MenuBarApplicationIcon, in group: MenuBarIconGroup) -> some View {
        // 停用、撤权、扫描和同步中不允许拖拽；点击查看入口信息不受影响。
        if canEditGroups {
            appTile(icon).draggable(icon.id)
                .overlay(alignment: .leading) {
                    insertionLine(visible: targetedGroup == group && insertionBeforeID == icon.id)
                }
                .dropDestination(for: String.self) { ids, _ in
                    acceptDrop(ids, to: group, before: icon.id)
                } isTargeted: { targeted in
                    updateDropTarget(group, before: icon.id, targeted: targeted)
                }
        } else {
            appTile(icon)
        }
    }

    private func groupEndTarget(_ group: MenuBarIconGroup, isEmpty: Bool) -> some View {
        HStack(spacing: 0) {
            if isEmpty {
                Text(L(emptyGroupMessage(group)))
                    .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    .lineLimit(1).padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 18, maxWidth: .infinity, minHeight: 38, maxHeight: 38)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            insertionLine(visible: canEditGroups && targetedGroup == group && insertionBeforeID == nil)
        }
        .dropDestination(for: String.self) { ids, _ in
            acceptDrop(ids, to: group, before: nil)
        } isTargeted: { targeted in
            updateDropTarget(group, before: nil, targeted: targeted)
        }
    }

    private func insertionLine(visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(visible ? ErmiTheme.link : .clear)
            .frame(width: 2, height: 30).offset(x: -3).allowsHitTesting(false)
    }

    private func updateDropTarget(_ group: MenuBarIconGroup, before targetID: String?, targeted: Bool) {
        if targeted && canEditGroups {
            targetedGroup = group
            insertionBeforeID = targetID
        } else if targetedGroup == group && insertionBeforeID == targetID {
            // 离开旧图标的回调不能清掉已进入的新位置，保证跨卡片时插入线连续反馈。
            targetedGroup = nil
            insertionBeforeID = nil
        }
    }

    private func acceptDrop(_ ids: [String], to group: MenuBarIconGroup, before targetID: String?) -> Bool {
        defer { targetedGroup = nil; insertionBeforeID = nil }
        // 拖放携带精确入口身份；搜索结果的下标和 App 身份都不能代替当前入口。
        guard canEditGroups, ids.count == 1, let id = ids.first, id != targetID,
              allIcons.contains(where: { $0.id == id }) else { return false }
        let changed = organizer.moveEntry(id, to: group, before: targetID)
        if changed { selectedID = id }
        return changed
    }

    private func appTile(_ icon: MenuBarApplicationIcon) -> some View {
        let app = icon.application
        let selected = selectedIcon?.id == icon.id
        return Button { selectedID = icon.id } label: {
            VStack(spacing: 3) {
                Image(nsImage: appIcon(app.id)).resizable().scaledToFit().frame(width: 22, height: 22)
                HStack(spacing: 2) {
                    Text(app.name).lineLimit(1).truncationMode(.tail)
                    // 序号不随长名称截断，两个 OpenVPN 入口仍能直接区分。
                    if app.count > 1 { Text("\(icon.index + 1)").monospacedDigit().fixedSize() }
                }.font(.system(size: 8))
            }
            .frame(width: 62, height: 38)
            .background(selected ? ErmiTheme.link.opacity(0.10) : (hoveredID == icon.id ? ErmiTheme.detailControl : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? ErmiTheme.link.opacity(0.55) : .clear, lineWidth: 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredID = icon.id } else if hoveredID == icon.id { hoveredID = nil }
        }
        .help(icon.name)
        .accessibilityLabel(icon.name + " · " + L(groupTitle(organizer.group(for: app.id))))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func fixedTile(id: String, name: String, symbol: String?) -> some View {
        let selected = selectedID == id
        return Button { selectedID = id } label: {
            VStack(spacing: 3) {
                Group {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 18)).frame(width: 22, height: 22)
                    } else {
                        ErmiLogo(size: 22)
                    }
                }.overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill").font(.system(size: 7))
                        .padding(2).background(ErmiTheme.detailCard, in: Circle()).offset(x: 4, y: 2)
                }
                Text(L(name)).font(.system(size: 8)).lineLimit(1)
            }
            .frame(width: 54, height: 38)
            .background(selected ? ErmiTheme.link.opacity(0.10) : (hoveredID == id ? ErmiTheme.detailControl : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? ErmiTheme.link.opacity(0.55) : .clear, lineWidth: 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredID = id } else if hoveredID == id { hoveredID = nil }
        }
        .help(L("始终保留，不能移动"))
        .accessibilityLabel(L(name) + " · " + L("始终保留，不能移动"))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var selectionActions: some View {
        HStack(spacing: 8) {
            if let icon = selectedIcon {
                let app = icon.application
                Text(icon.name)
                    .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).lineLimit(1)
                Spacer(minLength: 4)
                Button { organizer.shiftEntry(icon.id, by: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: 7)
                }.buttonStyle(ErmiDetailButtonStyle())
                    .disabled(!canEditGroups || !organizer.canShiftEntry(icon.id, by: -1))
                    .help(L("向左移动")).accessibilityLabel(L("向左移动"))
                Button { organizer.shiftEntry(icon.id, by: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 7)
                }.buttonStyle(ErmiDetailButtonStyle())
                    .disabled(!canEditGroups || !organizer.canShiftEntry(icon.id, by: 1))
                    .help(L("向右移动")).accessibilityLabel(L("向右移动"))
                ForEach(MenuBarIconGroup.allCases.filter { $0 != organizer.group(for: app.id) }, id: \.rawValue) { group in
                    Button(app.count > 1 ? L("移动整个 App") + " · " + L(groupTitle(group)) : L(moveTitle(group))) {
                        // 系统可见性按 App 生效，按钮明确说明整组操作；不会重排已有逐入口顺序。
                        organizer.setGroup(app.id, group)
                    }.buttonStyle(ErmiDetailButtonStyle()).disabled(!canEditGroups)
                }
            } else if selectedID?.hasPrefix("fixed:") == true {
                Label(L("始终保留，不能移动"), systemImage: "lock.fill")
                    .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                Spacer(minLength: 0)
            } else {
                Text(L("拖动调整顺序；点「同步菜单栏顺序」应用到顶部。"))
                    .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                Spacer(minLength: 0)
            }
        }.frame(height: 24).padding(.horizontal, 2)
    }

    private func emptyGroupMessage(_ group: MenuBarIconGroup) -> String {
        if organizer.refreshing { return "正在读取本机图标…" }
        if !query.isEmpty { return "没有符合条件的 App" }
        if organizer.applications.isEmpty { return "暂无可管理的菜单栏 App" }
        switch group {
        case .retained: return "拖入要保留的 App"
        case .folded: return "拖入要收起的 App"
        case .hidden: return "拖入要隐藏的 App"
        }
    }

    private func groupTitle(_ group: MenuBarIconGroup) -> String {
        switch group {
        case .retained: return "保留"
        case .folded: return "收起"
        case .hidden: return "隐藏"
        }
    }

    private func groupDescription(_ group: MenuBarIconGroup) -> String {
        switch group {
        case .retained: return "始终显示在菜单栏"
        case .folded: return "在展开栏中访问"
        case .hidden: return "收纳后不在菜单栏或展开栏显示"
        }
    }

    private func moveTitle(_ group: MenuBarIconGroup) -> String {
        switch group {
        case .retained: return "移至保留"
        case .folded: return "移至收起"
        case .hidden: return "移至隐藏"
        }
    }

    private var refreshButton: some View {
        Button(L(organizer.refreshing ? "读取中…" : "刷新")) { Task { await organizer.refreshFromUser() } }
            .buttonStyle(ErmiDetailButtonStyle()).disabled(organizer.refreshing || organizer.sorting)
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
