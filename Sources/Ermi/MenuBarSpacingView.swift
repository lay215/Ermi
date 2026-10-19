import SwiftUI

/// 与收纳列表分开，未授权读取图标时也可调整当前用户的间距偏好。
struct MenuBarSpacingView: View {
    let organizer: MenuBarOrganizer
    @State private var refresher = MenuBarSpacingRefresh()
    @State private var targets: [SpacingRefreshTarget] = []
    @State private var confirming = false
    @State private var preparing = false
    @State private var settings = MenuBarSpacing()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slider("图标间距", description: "调整系统菜单栏图标之间的距离。", value: $settings.spacing, range: 0...30)
            Divider().overlay(ErmiTheme.detailLine)
            slider("点击区域内边距", description: "调整每个图标两侧的点击区域。", value: $settings.padding, range: 0...20)
            Divider().overlay(ErmiTheme.detailLine)
            HStack {
                Text(L("预览")).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                Spacer()
                HStack(spacing: settings.spacing) {
                    ForEach(["wifi", "speaker.wave.2.fill", "battery.75percent", "magnifyingglass"], id: \.self) { symbol in
                        Image(systemName: symbol).font(.system(size: 13))
                            .frame(width: 18, height: 22).padding(.horizontal, settings.padding)
                            .background(ErmiTheme.detailLine.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    }
                }.accessibilityLabel(L("菜单栏图标间距示意"))
                Spacer()
            }.padding(10).background(ErmiTheme.detailControl, in: RoundedRectangle(cornerRadius: 6)).padding(12)
            VStack(alignment: .leading, spacing: 4) {
                Text(L(settings.savedDescription))
                Text(L("保存并应用会重启相关 App，图标会短暂消失。仅保存则在 App 下次启动或重新登录后生效。"))
            }.font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
            HStack(spacing: 12) {
                Button(L("恢复系统默认")) { refresher.clearMessage(); settings.reset() }
                    .help(L("清除当前用户的两项间距覆盖，包括其他工具保存的值"))
                Spacer()
                Button(L("仅保存")) { refresher.clearMessage(); settings.save() }
                Button(L(preparing ? "读取图标…" : "保存并应用")) {
                    preparing = true
                    Task {
                        await organizer.refresh()
                        targets = MenuBarSpacingRefresh.plan(applications: organizer.applications)
                        preparing = false
                        confirming = true
                    }
                }
                    .buttonStyle(ErmiDetailButtonStyle())
            }.font(.system(size: 9)).buttonStyle(ErmiDetailButtonStyle()).padding(12)
            if !refresher.message.isEmpty {
                Text(L(refresher.message)).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
            if !settings.message.isEmpty && refresher.message.isEmpty {
                Text(L(settings.message)).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).detailCard()
        .disabled(preparing || refresher.busy)
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("保存并刷新菜单栏")).font(.headline)
                Text(L("以下 App 会退出并重新打开，系统组件会重新加载。请先保存工作；拒绝退出的 App 将保留运行。"))
                    .font(.system(size: 12))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(targets) { Text($0.name) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
                if !organizer.authorized {
                    Text(L("尚未获得图标读取权限，本次只能刷新系统组件。请先在图标整理中授权，才能识别第三方 App。"))
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(L("只刷新本次识别到的项目。Ermi 自身及未列出的图标需下次启动后应用。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("取消")) { confirming = false }
                    Spacer()
                    Button(L("保存并刷新")) {
                        confirming = false
                        Task { await refresher.apply(targets: targets, save: { settings.save() }) }
                    }.buttonStyle(ErmiDetailButtonStyle())
                }
            }.buttonStyle(ErmiDetailButtonStyle()).padding(20).frame(width: 380)
        }
    }

    private func slider(_ title: String, description: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L(title)).font(.system(size: 10, weight: .medium))
                Text(L(description)).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Slider(value: value, in: range, step: 1).labelsHidden().accessibilityLabel(L(title))
                .tint(ErmiTheme.link).frame(width: 120)
            Text("\(Int(value.wrappedValue))").monospacedDigit().font(.system(size: 11))
                .frame(width: 24, alignment: .trailing)
        }.padding(12)
    }
}
