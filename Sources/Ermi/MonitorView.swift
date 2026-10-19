import SwiftUI
import ErmiCore

struct MonitorView: View {
    @Bindable var model: MonitorModel
    let detailed: Bool
    let openDetails: () -> Void
    var openPage: ((DetailPage) -> Void)? = nil
    var previewDialog = false
    @State private var pending: DisplayProcess?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if detailed { ErmiDetailView(model: model) }
            else { panel.ermiProcessConfirmation(pending: $pending, model: model) }
        }.preferredColorScheme(.light)
            .environment(\.locale, AppLocalization.shared.locale)
            .transaction { if reduceMotion { $0.disablesAnimations = true } }
            .task { if previewDialog && model.designPreview { pending = model.displayProcesses.first } }
    }

    // compact-v2 使用固定分区，图表与读数并排，避免缩小字号来压缩整体。
    private var panel: some View {
        VStack(spacing: 0) {
            top.frame(height: 48)
            hero.frame(height: 66)
            VStack(spacing: 0) {
                memorySection.frame(height: 85)
                divider
                processSection.frame(height: 123)
                divider
                VStack(spacing: 6) {
                    HStack {
                        Text(L("风扇")).font(.system(size: 11))
                        Spacer()
                        Text("\(model.fanRPM(0)) / \(model.fanRPM(1)) RPM")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(ErmiTheme.link)
                            .help("\(L(model.fanHelp(0)))\n\(L(model.fanHelp(1)))")
                    }
                    modeControl.frame(height: 33)
                    // 固定控制行保持各模式稳定，减少滑条上下空白且容纳两行错误提示。
                    controlDetail.frame(height: 26)
                }.padding(.horizontal, 13).padding(.top, 11)
                Spacer(minLength: 0)
            }.background(ErmiTheme.paper, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 8)
            // 移除底部重复入口后保留与侧边一致的留白，设置入口仍在标题栏。
            Color.clear.frame(height: 8)
        }
        .frame(width: ErmiTheme.panelWidth, height: ErmiTheme.panelHeight)
        .background(ErmiTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.15)))
        .foregroundStyle(ErmiTheme.ink)
    }

    private var divider: some View { Rectangle().fill(ErmiTheme.line).frame(height: 1).padding(.horizontal, 13) }
    private var top: some View {
        HStack(spacing: 8) {
            ErmiLogo(size: 24)
            Text("Ermi").font(.system(size: 13, weight: .semibold)).foregroundStyle(ErmiTheme.header)
            Spacer()
            Button { navigate(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(ErmiTheme.ice).frame(width: 26, height: 26)
            }.buttonStyle(ErmiPressStyle()).help(L("打开系统设置")).accessibilityLabel(L("打开系统设置"))
        }.padding(.horizontal, 21)
    }
    private var hero: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 0) {
                    Text(model.cpuTemperatureText).font(.system(size: 39, weight: .regular)).tracking(-1.5)
                    Text("°C").font(.system(size: 18)).padding(.top, 4)
                }.frame(height: 40)
            }.help(L(model.temperatureHelp))
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 5) { Circle().fill(thermalColor).frame(width: 5, height: 5); Text(L(model.thermalText)) }
                Text("CPU \(model.cpuText)% · GPU \(model.gpuTemperatureText)°C").foregroundStyle(ErmiTheme.ice)
            }.font(.system(size: 10))
        }.foregroundStyle(ErmiTheme.header).padding(.horizontal, 21).padding(.bottom, 12)
    }
    private var thermalColor: Color {
        if model.designPreview { return ErmiTheme.green }
        switch model.snapshot?.thermalState {
        case .nominal: return ErmiTheme.green
        case .fair: return Color(hex: 0xc5a76b)
        case .serious: return Color(hex: 0xd28c58)
        case .critical: return Color(hex: 0xc8756b)
        default: return ErmiTheme.muted
        }
    }
    private var memorySection: some View {
        VStack(spacing: 6) {
            HStack {
                Text(L("内存")).font(.system(size: 11))
                Spacer()
                Text(L(model.memoryPressureText))
                    .font(.system(size: 10)).foregroundStyle(ErmiTheme.muted)
            }
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(model.memoryGB).font(.system(size: 22)).tracking(-0.6)
                    Text("/ \(model.totalMemoryGB) GiB").font(.system(size: 11)).foregroundStyle(ErmiTheme.muted)
                }.monospacedDigit()
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    R4LineChart(values: model.memoryHistory, filled: true).frame(width: 127, height: 28)
                    Text(L("近 60 秒 · \(model.memoryPercentText)%")).font(.system(size: 9)).foregroundStyle(ErmiTheme.muted)
                }
            }
        }.padding(.horizontal, 13).padding(.vertical, 10)
    }
    private var processSection: some View {
        VStack(spacing: 3) {
            HStack {
                Text(L("占用较高的 App")).font(.system(size: 11))
                Spacer()
                Button(L(model.sortByMemory ? "按内存 ↓" : "按 CPU ↓")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { model.sortByMemory.toggle() }
                }.font(.system(size: 10)).foregroundStyle(ErmiTheme.link).buttonStyle(ErmiPressStyle())
                    .accessibilityLabel(L("排序方式：\(model.sortByMemory ? "内存" : "CPU")，点击切换"))
            }.frame(height: 21)
            ForEach(Array(model.displayProcesses.prefix(3))) { process in
                HStack(spacing: 8) {
                    ProcessAppIcon(process: process, size: 17)
                    Text(process.name).font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L(model.sortByMemory ? process.memory : "\(process.cpu)%"))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(ErmiTheme.link).frame(width: 58, alignment: .trailing)
                    ProcessStopButton { pending = process }.disabled(model.isStopping).accessibilityLabel(L("结束 \(process.name)"))
                }.frame(height: 25)
            }
            if model.displayProcesses.isEmpty { Text(L("正在读取进程…")).font(.system(size: 10)).foregroundStyle(ErmiTheme.muted).frame(maxWidth: .infinity, minHeight: 70) }
        }.padding(.horizontal, 13).padding(.vertical, 8)
    }

    private var modeControl: some View {
        GeometryReader { g in
            let width = (g.size.width - 6) / 3
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(ErmiTheme.control)
                RoundedRectangle(cornerRadius: 6).fill(ErmiTheme.selected)
                    .shadow(color: ErmiTheme.ink.opacity(0.15), radius: 2.5, y: 2.5)
                    .frame(width: width, height: 27).offset(x: 3 + CGFloat(model.displayedFanMode.rawValue) * width)
                HStack(spacing: 0) {
                    ForEach(FanMode.allCases, id: \.rawValue) { mode in
                        Button {
                            // 先呈现用户选择，等待期间明确显示进度；确认状态仍由模型回读维护。
                            model.selectFanMode(mode)
                        } label: {
                            Text(L(mode == .system ? "系统" : mode == .auto ? "自动调节" : "固定转速")).font(.system(size: 10, weight: mode == model.displayedFanMode ? .semibold : .regular))
                                .foregroundStyle(mode == model.displayedFanMode ? .white : ErmiTheme.muted).frame(maxWidth: .infinity).frame(height: 27)
                        }.buttonStyle(.plain).accessibilityAddTraits(mode == model.displayedFanMode ? [.isSelected] : [])
                    }
                }.padding(3)
            }.animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.displayedFanMode)
        }
    }

    private var controlDetail: some View {
        Group {
            // 错误与未授权必须有可发现入口，不能在紧凑布局中被截断后静默隐藏。
            // 所有模式提交期间保留对应控件，不用加载文案替换；回包失败后仍展示真实错误。
            if model.pendingFanMode == nil && model.controlNeedsAttention && !model.designPreview {
                HStack {
                    Text(L(model.controlNotice)).lineLimit(2).help(L(model.controlNotice))
                    Spacer(minLength: 3)
                    Button(L("详情 ↗")) { navigate(.presets) }.fixedSize().buttonStyle(ErmiPressStyle())
                }
            } else if model.displayedFanMode == .auto {
                HStack {
                    R4ChoiceMenu(selection: Binding(get: { model.strategyTitle }, set: { selection in
                        model.strategy = selection == "日常均衡" ? "均衡" : selection
                        if !model.designPreview { model.selectFanMode(.auto) }
                    }), options: ["日常均衡", "积极散热"], bordered: false).disabled(model.controlBusy)
                    Spacer()
                    Button(L("管理方案 ↗")) { navigate(.presets) }.buttonStyle(ErmiPressStyle())
                }
            } else if model.displayedFanMode == .fixed {
                HStack(spacing: 10) {
                    R4Slider(value: $model.targetRPM, range: model.designPreview ? 2000...5000 : model.fanRPMRange) {
                        if !model.designPreview { model.applyFixedRPM() }
                    }.frame(height: 20).disabled(model.controlBusy)
                    Text(L(model.independentTargets ?? "\(Int(model.targetRPM).formatted()) RPM")).monospacedDigit().fixedSize()
                }
            } else {
                HStack {
                    Text(L(model.pendingFanMode == .system ? "使用 macOS 默认转速策略。" : (model.designPreview ? "由 macOS 自动管理转速。" : "Ermi 未接管风扇控制。")))
                    Spacer(minLength: 0)
                    if !model.helperReady && !model.designPreview {
                        Button(L("启用控制 ↗")) { Task { await model.enableFanControl() } }.buttonStyle(ErmiPressStyle())
                    }
                }
            }
        }.font(.system(size: 10)).foregroundStyle(ErmiTheme.muted)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.displayedFanMode)
    }

    private func navigate(_ page: DetailPage) {
        model.detailPage = page
        if let openPage { openPage(page) } else { openDetails() }
    }
}

struct R4Slider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onEditingEnded: () -> Void = {}
    var body: some View {
        GeometryReader { g in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(ErmiTheme.line).frame(height: 5)
                Capsule().fill(ErmiTheme.selected).frame(width: max(0, g.size.width * fraction), height: 5)
                Circle().fill(ErmiTheme.card).overlay(Circle().strokeBorder(ErmiTheme.line, lineWidth: 1)).shadow(color: ErmiTheme.ink.opacity(0.15), radius: 2, y: 1)
                    .frame(width: 17, height: 17).offset(x: (g.size.width - 17) * fraction)
            }.frame(maxHeight: .infinity)
                .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let raw = min(1, max(0, event.location.x / max(1, g.size.width))) * (range.upperBound - range.lowerBound) + range.lowerBound
                    // 硬件边界未必是100的倍数，四舍五入后仍需夹紧。
                    value = min(range.upperBound, max(range.lowerBound, (raw / 100).rounded() * 100))
                }.onEnded { _ in onEditingEnded() })
        }.focusable()
            // 保留键盘与辅助功能调节，仅去除自绘滑杆外围的系统蓝色焦点框。
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { adjust(-100); return .handled }
            .onKeyPress(.rightArrow) { adjust(100); return .handled }
            .accessibilityLabel(L("固定目标转速")).accessibilityValue(L("\(Int(value)) RPM"))
            .accessibilityAdjustableAction { direction in adjust(direction == .increment ? 100 : -100) }
    }
    private func adjust(_ delta: Double) {
        value = min(range.upperBound, max(range.lowerBound, value + delta))
        onEditingEnded()
    }
}
