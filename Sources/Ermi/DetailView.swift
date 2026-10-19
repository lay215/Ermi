import SwiftUI
import AppKit
import ErmiCore

/// 紧凑详情页固定窗口尺寸；仅列表滚动，编辑状态跨页保留。
struct ErmiDetailView: View {
    @Bindable var model: MonitorModel
    var integratedChrome = false
    var previewOrganizer: MenuBarOrganizer? = nil
    @State private var editing = false
    @State private var deleting: FanPreset?
    @State private var editorFeedback = ""
    @State private var editingID: UUID?
    @State private var originalRule: FanThermalRule?
    @State private var presetName = "我的方案"
    @State private var kind = "自动调节"
    @State private var sensor = "CPU"
    @State private var startTemperature = "55"
    @State private var endTemperature = "80"
    @State private var targetRPMs: [Int: String] = [:]
    @State private var localFeedback = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("ermi.reduceMotion") private var prefersReducedMotion = false
    @Namespace private var tabSelection

    private var motionDisabled: Bool { reduceMotion || prefersReducedMotion }

    var body: some View {
        VStack(spacing: 0) {
            navigation
            // 四页保留稳定身份和滚动位置；只动画页面容器，实时指标不参与插值。
            ZStack(alignment: .topLeading) {
                pageLayer(.monitor) { ErmiSystemOverview(model: model) }
                pageLayer(.presets) {
                    ScrollView { presets.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .topLeading) }
                }
                pageLayer(.settings) { AppSettingsView(model: model, embedded: true, isActive: model.detailPage == .settings) }
                pageLayer(.icons) { ScrollView { IconOrganizerView(organizer: previewOrganizer ?? model.iconOrganizer, isActive: model.detailPage == .icons).padding(.horizontal, 16).padding(.vertical, 10) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .background(ErmiTheme.detailBackground).foregroundStyle(ErmiTheme.detailInk).preferredColorScheme(.light)
        .tint(ErmiTheme.link)
        .environment(\.locale, AppLocalization.shared.locale)
        // Sheet 保留原页面视图与滚动位置；编辑不再用条件分支替换方案列表。
        .sheet(isPresented: $editing) {
            editor.frame(width: 460).padding(16)
                .background(ErmiTheme.detailBackground).foregroundStyle(ErmiTheme.detailInk)
                .interactiveDismissDisabled(model.presetBusy)
        }
        .alert(L("删除“\(deleting?.name ?? "")”？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { preset in
            Button(L("取消"), role: .cancel) { deleting = nil }
            Button(L("删除方案"), role: .destructive) {
                deleting = nil
                Task { localFeedback = await model.deleteFanPreset(preset) }
            }
        } message: { _ in Text(L("仅删除保存的方案，当前风扇运行不受影响。")) }
    }

    private func pageLayer<Content: View>(_ page: DetailPage, @ViewBuilder content: () -> Content) -> some View {
        let selected = model.detailPage == page
        // 页面只交叉淡入，避免整张实时列表平移时重复合成；保留视图身份与滚动位置。
        return content()
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(selected ? 1 : 0)
            // 隐藏页不能接收鼠标、键盘和读屏焦点；快速连续切换直接从当前动画状态衔接。
            .allowsHitTesting(selected)
            .disabled(!selected)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(!selected)
            .zIndex(selected ? 1 : 0)
            .animation(motionDisabled ? nil : .easeOut(duration: 0.16), value: model.detailPage)
    }

    private var navigation: some View {
        // 导航以整个窗口为中心；左右保留等宽空间，避免左侧窗口按钮把导航重心推向右边。
        HStack(spacing: 6) {
            tab(.monitor, "系统概览").keyboardShortcut("1", modifiers: .command)
            tab(.presets, "风扇调节").keyboardShortcut("2", modifiers: .command)
            tab(.icons, "图标整理").keyboardShortcut("3", modifiers: .command)
            tab(.settings, "系统设置").keyboardShortcut("4", modifiers: .command)
        }
        .padding(.horizontal, integratedChrome ? 108 : 16)
        .frame(maxWidth: .infinity).frame(height: 48)
        .overlay(alignment: .leading) {
            if integratedChrome {
                HStack(spacing: 6) {
                    ErmiWindowTitlebar().frame(width: 70, height: 48)
                    ErmiLogo(size: 20).accessibilityLabel(L("Ermi"))
                }
            }
        }
        .background(ErmiTheme.detailBackground)
        .background { if integratedChrome { ErmiWindowDragRegion() } }
        .animation(motionDisabled ? nil : .smooth(duration: 0.26, extraBounce: 0), value: model.detailPage)
    }
    private func tab(_ page: DetailPage, _ title: String) -> some View {
        Button { model.detailPage = page } label: {
            // 四个导航项共享一行；英文标题允许轻微缩放，保留原生窗口按钮空间。
            Text(L(title)).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(model.detailPage == page ? ErmiTheme.detailInk : ErmiTheme.detailMuted)
                .padding(.horizontal, 8).frame(height: 28)
                .background {
                    if model.detailPage == page {
                        RoundedRectangle(cornerRadius: 7).fill(ErmiTheme.detailCard)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            .matchedGeometryEffect(id: "detail-tab", in: tabSelection)
                    }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(model.detailPage == page ? .isSelected : [])
    }
    private func heading(_ title: String, badge: String) -> some View {
        HStack {
            Text(L(title)).font(.system(size: 17, weight: .semibold)).tracking(-0.3)
            Spacer()
            Text(L(badge)).font(.system(size: 10)).foregroundStyle(ErmiTheme.detailMuted).lineLimit(1)
        }.frame(height: 22)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("风扇调节")).font(.system(size: 13, weight: .semibold))
                    Text(L("根据当前负载选择散热方式。")).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                }
                Spacer()
                Text(L(model.helperReady ? "风扇服务已连接" : "风扇服务未连接"))
                    .font(.system(size: 8)).foregroundStyle(model.helperReady ? Color(hex: 0x578574) : ErmiTheme.detailMuted)
            }.padding(.horizontal, 2).padding(.bottom, 1)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("当前转速")).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    ScrollView(.horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            ForEach(model.displayedFanIndices, id: \.self) { fanReading($0) }
                            if model.displayedFanIndices.isEmpty { Text("— RPM") }
                        }
                    }.scrollIndicators(.hidden)
                }
                Spacer()
                action("交还系统") { model.selectFanMode(.system) }
            }.padding(12).detailCard()
            // 模式选择复用面板的授权与排队入口；不绕开真实服务状态或另起控制链路。
            ErmiSegmentedControl(options: model.canApplyFanControl ? FanMode.allCases : [.system], selection: Binding(
                get: { model.displayedFanMode },
                set: { mode in
                    if model.designPreview { model.fanMode = mode }
                    else { model.selectFanMode(mode) }
                }
            )) { mode in
                mode == .system ? "系统" : mode == .auto ? "自动调节" : "固定转速"
            }
            if (!model.helperReady || model.fanCapabilityIssue != nil) && !model.designPreview && !model.isFanless { serviceSetup }
            if let issue = model.fanCapabilityIssue { Text(L(issue)).font(.system(size: 9)).foregroundStyle(ErmiTheme.detailMuted) }
            if model.controlNeedsAttention && !model.controlNotice.isEmpty && model.controlNotice != model.fanCapabilityIssue && !model.designPreview {
                Text(L(model.controlNotice)).font(.system(size: 9)).foregroundStyle(ErmiTheme.detailMuted).fixedSize(horizontal: false, vertical: true)
            }
            if model.displayedFanMode == .auto {
                planList
            } else if model.displayedFanMode == .fixed {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("固定目标转速")).font(.system(size: 10, weight: .medium))
                        Text(L("所有风扇使用相同目标值。")).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    }
                    Spacer(minLength: 4)
                    R4Slider(value: $model.targetRPM, range: model.designPreview ? 2000...5600 : model.fanRPMRange) {
                        if !model.designPreview { model.applyFixedRPM() }
                    }.frame(width: 145, height: 24).disabled(model.controlBusy || !model.canApplyFanControl)
                    Text(model.independentTargets ?? "\(Int(model.targetRPM).formatted()) RPM").font(.system(size: 10)).monospacedDigit().fixedSize()
                }.padding(12).detailCard()
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("由 macOS 管理")).font(.system(size: 10, weight: .medium))
                    Text(L("系统根据温度与负载自动调整风扇转速。")).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).detailCard()
            }
            if !localFeedback.isEmpty { Text(L(localFeedback)).font(.system(size: 9)).foregroundStyle(ErmiTheme.detailMuted).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func fanReading(_ index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(model.fanRPM(index)).font(.system(size: 16, weight: .medium)).monospacedDigit()
            Text("RPM").font(.system(size: 7)).foregroundStyle(ErmiTheme.detailMuted)
            Text(L(model.fanLabel(index))).font(.system(size: 7)).foregroundStyle(ErmiTheme.detailMuted)
        }.padding(.trailing, 12)
    }
    private var serviceSetup: some View {
        // 正常连接时不展示维护卡片；显式重试仍走原授权入口，不自动重放调速操作。
        HStack(spacing: 10) {
            Text(L(model.installerOpening ? "请在系统窗口完成授权…" : model.fanCapabilityIssue != nil ? "风扇控制能力暂不可用，请重试连接。" : model.needsFanAuthorization ? "调节风扇前需要授权控制服务。" : "风扇服务暂未连接，正在自动重连。"))
                .font(.system(size: 11)).foregroundStyle(ErmiTheme.detailMuted)
            Spacer()
            action(model.fanServiceActionTitle, primary: true) { Task { await model.enableFanControl() } }
                .disabled(model.controlBusy || model.installerOpening)
        }.padding(10).detailCard()
    }
    private var planList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                builtin("日常均衡", name: "均衡", subtitle: "日常办公、浏览网页", symbol: "leaf", upper: 80)
                SettingsDivider()
                builtin("积极散热", name: "积极散热", subtitle: "更早加速，适合持续高负载；风声更明显", symbol: "wind", upper: 70)
            }.detailCard()
            HStack {
                Text(L("我的方案")).font(.system(size: 11))
                Spacer()
                Button(L("＋ 新建方案")) { beginEdit(nil) }.buttonStyle(.plain).font(.system(size: 10))
            }.padding(.top, 12).padding(.bottom, 7)
            if model.fanPresets.isEmpty {
                VStack(spacing: 7) {
                    Text(L("还没有自定义方案")).font(.system(size: 9, weight: .medium))
                    Text(L("按温度曲线或固定转速，保存适合你的散热设置。")).font(.system(size: 8))
                }.foregroundStyle(ErmiTheme.detailMuted).frame(maxWidth: .infinity).padding(.vertical, 20).detailCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(model.fanPresets) { preset in
                        HStack(spacing: 10) {
                            Image(systemName: "slider.horizontal.3").frame(width: 22).foregroundStyle(ErmiTheme.detailMuted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name).font(.system(size: 12)).lineLimit(1)
                                Text(L(presetSummary(preset))).font(.system(size: 10)).foregroundStyle(ErmiTheme.detailMuted).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(L("编辑")) { beginEdit(preset) }.font(.system(size: 10)).buttonStyle(.plain).frame(width: 36)
                            Button { deleting = preset } label: {
                                Image(systemName: "trash").frame(width: 24, height: 26)
                            }.buttonStyle(ErmiPressStyle()).foregroundStyle(ErmiTheme.detailMuted)
                                .help(L("删除方案")).accessibilityLabel(L("删除 \(preset.name)")).disabled(model.presetBusy)
                            useButton(preset)
                        }.padding(.horizontal, 12).frame(minHeight: 46)
                        if preset.id != model.fanPresets.last?.id { Divider() }
                    }
                }.detailCard()
            }
        }
    }
    private func builtin(_ title: String, name: String, subtitle: String, symbol: String, upper: Double) -> some View {
        let preset = FanPreset(name: name, configuration: .thermal(.init(sensor: .maxCPUAndGPU, lowerTemperature: 50, upperTemperature: upper)))
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title)).font(.system(size: 10, weight: .semibold))
                Text(L(subtitle)).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            useButton(preset)
        }.padding(.horizontal, 12).frame(minHeight: 46)
    }
    private func useButton(_ preset: FanPreset) -> some View {
        // 使用中只依据服务已确认的配置，不能将选中或保存状态当成硬件成功。
        let active = model.fanStatus.phase == .applied && model.fanStatus.preset?.configuration == preset.configuration
        return Button { model.applyFanPreset(preset) } label: {
            Text(L(active ? "✓ 使用中" : "使用")).font(.system(size: 10)).frame(width: 56, height: 24)
                .foregroundStyle(active ? Color(hex: 0x548d7c) : ErmiTheme.detailInk)
                .background(active ? .clear : ErmiTheme.detailControl, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(ErmiPressStyle()).disabled(active || model.controlBusy || model.designPreview || !model.canApplyFanControl)
    }
    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L(editingID == nil ? "新建方案" : "编辑方案")).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(L("关闭")) { editing = false }.font(.system(size: 10)).buttonStyle(.plain)
            }.padding(.bottom, 4)
            field("名称") { TextField(L("方案名称"), text: $presetName).textFieldStyle(.roundedBorder).frame(width: 160) }
            field("调节方式") { Picker(L("调节方式"), selection: $kind) { Text(L("自动调节")).tag("自动调节"); Text(L("固定转速")).tag("固定转速") }.labelsHidden().frame(width: 180) }
            VStack(spacing: 0) {
            if kind == "自动调节" {
                field("温度来源") { Picker(L("温度来源"), selection: $sensor) { ForEach(["CPU", "GPU", "CPU / GPU 最高"], id: \.self) { Text(L($0)) } }.labelsHidden().frame(width: 180) }
                field("开始加速") { number($startTemperature, unit: "°C") }
                field("达到全速") { number($endTemperature, unit: "°C") }
            } else {
                // 不同 Mac 有不同数量和编号的风扇，独立目标以能力中的设备索引绑定。
                ScrollView {
                    ForEach(model.fanCapabilities.sorted { $0.index < $1.index }, id: \.index) { fan in
                        field("\(fan.name)目标") {
                            number(Binding(get: { targetRPMs[fan.index] ?? "" }, set: { targetRPMs[fan.index] = $0 }), unit: "RPM")
                        }
                    }
                }
            }
            }.frame(height: 84, alignment: .top)
            // 校验信息预留两行，切换调节方式或报错均不改变弹层尺寸。
            Text(L(editorFeedback)).font(.system(size: 10)).foregroundStyle(ErmiTheme.detailMuted)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
            HStack {
                Text(L("保存不会立即改变转速")).font(.system(size: 10)).foregroundStyle(ErmiTheme.detailMuted)
                Spacer()
                action("取消") { editing = false }
                action("保存方案", primary: true, action: save)
            }.padding(.top, 10)
        }.padding(12).detailCard().disabled(model.presetBusy)
            .onExitCommand { if !model.presetBusy { editing = false } }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack { Text(L(label)); Spacer(); content() }.font(.system(size: 11)).frame(height: 28).overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
    private func number(_ value: Binding<String>, unit: String) -> some View {
        HStack(spacing: 5) { TextField(L(""), text: value).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 85); Text(unit).frame(width: 24, alignment: .leading) }
    }
    private func action(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(L(title)).font(.system(size: 10)).padding(.horizontal, 10).frame(height: 26).foregroundStyle(primary ? .white : ErmiTheme.detailInk).background(primary ? ErmiTheme.selected : ErmiTheme.detailControl, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(ErmiPressStyle()).disabled(model.controlBusy)
    }
    private func presetSummary(_ preset: FanPreset) -> String {
        switch preset.configuration {
        case .thermal(let rule): return "\(rule.sensor == .cpu ? "CPU" : rule.sensor == .gpu ? "GPU" : "CPU / GPU") · \(Int(rule.lowerTemperature))°C 开始，\(Int(rule.upperTemperature))°C 全速"
        case .fixed(let rpm): return "固定目标 · \(Int(rpm)) RPM"
        case .fixedTargets(let targets): return targets.sorted { $0.index < $1.index }.map { "\(Int($0.rpm))" }.joined(separator: " / ") + " RPM"
        }
    }
    private func beginEdit(_ preset: FanPreset?) {
        editingID = preset?.id; originalRule = nil; presetName = preset?.name ?? L("我的方案"); editorFeedback = ""
        kind = "自动调节"; sensor = "CPU"; startTemperature = "55"; endTemperature = "80"; targetRPMs = Dictionary(uniqueKeysWithValues: model.fanCapabilities.map { ($0.index, String(min(max(3200, $0.minimumRPM), $0.maximumRPM))) })
        if let preset {
            switch preset.configuration {
            case .thermal(let rule):
                originalRule = rule; sensor = rule.sensor == .cpu ? "CPU" : rule.sensor == .gpu ? "GPU" : "CPU / GPU 最高"
                startTemperature = String(rule.lowerTemperature); endTemperature = String(rule.upperTemperature)
            case .fixed(let rpm): kind = "固定转速"; targetRPMs = Dictionary(uniqueKeysWithValues: model.fanCapabilities.map { ($0.index, String(rpm)) })
            case .fixedTargets(let targets):
                kind = "固定转速"
                targetRPMs = Dictionary(uniqueKeysWithValues: targets.map { ($0.index, String($0.rpm)) })
            }
        }
        editing = true
    }
    private func save() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { editorFeedback = "请填写方案名称。"; return }
        let configuration: FanControlConfiguration
        if kind == "自动调节" {
            guard let start = Double(startTemperature), let end = Double(endTemperature), start.isFinite, end.isFinite, start >= 0, end <= 150, start < end else { editorFeedback = "温度须在 0–150°C 内，开始温度低于全速温度。"; return }
            // 编辑保留既有的 RPM 限制和爬升速率，界面未呈现的安全参数不能被默认值覆盖。
            var rule = originalRule ?? FanThermalRule(sensor: .cpu, lowerTemperature: start, upperTemperature: end)
            rule.sensor = sensor == "GPU" ? .gpu : sensor == "CPU" ? .cpu : .maxCPUAndGPU
            rule.lowerTemperature = start; rule.upperTemperature = end; configuration = .thermal(rule)
        } else {
            let capabilities = model.fanCapabilities.sorted { $0.index < $1.index }
            let values = capabilities.compactMap { Double(targetRPMs[$0.index] ?? "") }
            guard !capabilities.isEmpty, values.count == capabilities.count, values.allSatisfy(\.isFinite) else { editorFeedback = "请等待读取风扇范围，并填写每只风扇的有效目标转速。"; return }
            for (fan, rpm) in zip(capabilities, values) {
                guard rpm >= fan.minimumRPM, rpm <= fan.maximumRPM else { editorFeedback = "\(fan.name) 允许 \(Int(fan.minimumRPM))–\(Int(fan.maximumRPM)) RPM。"; return }
            }
            // 按设备索引匹配目标，避免用左右位置猜测 SMC 编号。
            configuration = .fixedTargets(zip(capabilities, values).map { FanRPMTarget(index: $0.0.index, rpm: $0.1) })
        }
        let preset = FanPreset(id: editingID ?? UUID(), name: name, configuration: configuration)
        // 保存只持久化，必须由用户另点“使用”才能请求硬件控制。
        Task {
            editorFeedback = await model.saveFanPreset(preset)
            if model.fanPresets.contains(where: { $0 == preset }) { editing = false; localFeedback = editorFeedback }
        }
    }
}

extension View {
    func detailCard() -> some View {
        background(ErmiTheme.detailCard, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(ErmiTheme.detailLine, lineWidth: 0.5))
    }
}

// 将实时采样的观察范围收在概览子视图内，避免每次采样重算所有 Tab 与方案编辑器。
private struct ErmiSystemOverview: View {
    @Bindable var model: MonitorModel
    @State private var pending: DisplayProcess?
    @State private var memoryTrend = false
    var body: some View {
        // 采样只在概览派生一次列表；重排视觉不改变排序、退出确认及数据来源。
        let processes = model.detailProcesses
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("系统概览")).font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 7) {
                        Text(model.snapshot?.hardwareModel ?? "Mac")
                        Circle().fill(ErmiTheme.green).frame(width: 4, height: 4)
                        Text(L(model.thermalText))
                    }.font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                }
                Spacer()
                if model.designPreview { Text(L("示例数据")).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted) }
            }.padding(.horizontal, 2).frame(height: 34)
            HStack(spacing: 0) {
                metric("CPU", value: model.cpuText + "%", detail: "CPU \(model.cpuTemperatureText)° · GPU \(model.gpuTemperatureText)°")
                Divider().padding(.vertical, 11)
                metric("内存", value: model.memoryGB + " GiB", detail: "\(model.memoryPressureText) · \(model.memoryPercentText)%")
                Divider().padding(.vertical, 11)
                metric("可用空间 · GB", value: model.diskAvailableText, detail: model.diskDetailText).help(L(model.diskHelp))
                Divider().padding(.vertical, 11)
                metric("电池", value: model.batteryText, detail: model.batteryDetailText)
            }.frame(height: 70).detailCard()
            VStack(spacing: 6) {
                HStack {
                    ErmiSegmentedControl(options: [false, true], selection: $memoryTrend,
                                         minimumSegmentWidth: 38, fontSize: 8, segmentHeight: 20) { $0 ? "内存" : "CPU" }
                    Spacer()
                    Text(L("近 60 秒")).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                }
                R4LineChart(values: memoryTrend ? model.memoryHistory : model.cpuHistory, filled: true,
                    chartLabel: memoryTrend ? "内存近60秒趋势" : "CPU近60秒趋势").frame(height: 44)
            }.padding(10).detailCard()
            VStack(spacing: 0) {
                HStack {
                    Text(L("高占用进程")).font(.system(size: 10, weight: .semibold))
                    Text(L("· \(processes.count) 个")).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                    Spacer()
                    DetailMenu(title: "排序", selection: $model.detailSortByMemory,
                        options: [(false, "按 CPU 排序"), (true, "按内存排序")]).frame(width: 94)
                }.padding(.horizontal, 11).frame(height: 29)
                processTable(processes)
            }.detailCard().frame(maxHeight: .infinity)
            HStack {
                Text(L(model.feedback.isEmpty ? model.networkText : model.feedback)).lineLimit(1).help(L(model.feedback.isEmpty ? model.networkHelp : model.feedback))
                Spacer()
                Text(L(model.uptimeText) + L(" · CPU：单核 100%")).help(L("进程 CPU 以单个核心为 100%，可能超过 100%，与整机使用率分母不同。"))
            }.font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).padding(.horizontal, 2)
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
            .ermiProcessConfirmation(pending: $pending, model: model)
    }
    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L(title)).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
            Text(L(value)).font(.system(size: 16, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            Text(L(detail)).font(.system(size: 7)).foregroundStyle(ErmiTheme.detailMuted).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
    }
    private func processTable(_ processes: [DisplayProcess]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("进程")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("内存")).frame(width: 70, alignment: .trailing)
                Text("CPU").frame(width: 52, alignment: .trailing)
                Color.clear.frame(width: 18, height: 1)
            }.font(.system(size: 7)).foregroundStyle(ErmiTheme.detailMuted)
                .padding(.horizontal, 11).frame(height: 18).background(ErmiTheme.detailBackground.opacity(0.6))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(processes) { process in
                        HStack(spacing: 8) {
                            ProcessAppIcon(process: process, size: 14)
                            Text(process.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(process.memory).frame(width: 70, alignment: .trailing)
                            Text(process.cpu).frame(width: 52, alignment: .trailing)
                            Button { pending = process } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(ErmiTheme.detailMuted).frame(width: 18, height: 16)
                                    .background(ErmiTheme.detailControl, in: RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain).disabled(model.isStopping).accessibilityLabel(L("退出 \(process.name)"))
                        }.font(.system(size: 8)).monospacedDigit().padding(.horizontal, 11).frame(height: 24)
                            .overlay(alignment: .top) { Rectangle().fill(ErmiTheme.detailLine.opacity(0.6)).frame(height: 0.5) }
                    }
                    if processes.isEmpty {
                        Text(L("正在采集进程…")).font(.system(size: 9)).foregroundStyle(ErmiTheme.detailMuted).padding(12)
                    }
                }
            }
        }
    }

}
