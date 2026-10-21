import AppKit
import Observation
import ErmiCore
import Darwin

// 仅抽取模型实际使用的服务入口，测试可阻塞回包来验证睡眠与唤醒交错，不触碰硬件。
@MainActor protocol FanControlConnection: AnyObject {
    var usesLocalMode: Bool { get }
    var localSetupMessage: String { get }
    var ready: Bool { get }
    func refreshAvailability() async throws
    func enable() async throws
    func request(_ command: FanServiceCommand) async throws -> FanServiceReply
    func disconnect()
}
extension FanControlConnection {
    func refreshAvailability() async throws {}
}
extension FanControlClient: FanControlConnection {}

@MainActor @Observable
final class MonitorModel {
    var snapshot: SystemSnapshot? {
        didSet { onSnapshot?(snapshot) }
    }
    // 同一快照同时驱动菜单栏摘要和浮层，避免各自采样产生口径或刷新差异。
    @ObservationIgnored var onSnapshot: ((SystemSnapshot?) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    // 只控制菜单栏摘要；关闭后仍正常采样，浮层温度与风扇控制不受影响。
    var showMenuBarTemperature: Bool {
        didSet {
            defaults.set(showMenuBarTemperature, forKey: "ermi.showMenuBarTemperature")
            onSnapshot?(snapshot)
        }
    }
    var sortByMemory = true
    var detailSortByMemory = false
    var detailPage: DetailPage = .monitor
    let iconOrganizer = MenuBarOrganizer()
    var fanMode: FanMode = .system
    // 交互选中态即时响应；fanMode 始终保留设备确认值，不能把请求当作硬件已生效。
    private(set) var pendingFanMode: FanMode?
    private var queuedFanMode: FanMode?
    var displayedFanMode: FanMode { pendingFanMode ?? fanMode }
    var designPreview = false
    var controlNotice = ""
    var controlNeedsAttention = false
    var controlBusy = false
    var installerOpening = false
    var helperReady = false
    var usesLocalFanControl = false
    var localFanSetupMessage = ""
    var fanCapabilities: [FanCapability] = []
    // 只有明确的探测结果才能判定不可控；尚未读取不等于无风扇。
    private(set) var fanCapabilityIssue: String?
    private(set) var isFanless = false
    var canApplyFanControl: Bool { designPreview || fanCapabilityIssue == nil }
    // 候选扫描由真实窗口可见性约束，SwiftUI 缓存的页面不能令后台持续扫描所有温度键。
    var temperatureSensorEditorActive = false
    var temperatureSensorPanelVisible = false
    var temperatureSensorDetailVisible = false
    var shouldSampleTemperatureSensors: Bool {
        // 具体传感器也用于弹窗主温度；系统或固定模式下打开弹窗仍需刷新该读数，隐藏后停止额外扫描。
        isVisible && (temperatureSensorEditorActive || (temperatureSensorPanelVisible &&
            (displayedFanMode == .auto || defaultFanTemperatureSource == .sensor)) ||
            (temperatureSensorDetailVisible && detailPage == .presets))
    }
    private(set) var supportsTemperatureSensorSelection = false
    var temperatureSensors: [TemperatureSensorReading] { snapshot?.hardware.temperatureSensors ?? [] }
    // 展示以服务确认的内置规则为准；回读其他控制者状态不会修改本机保存的内置来源偏好。
    var defaultFanTemperatureSource: FanTemperatureSource { activeBuiltinThermalRule?.sensor ?? savedDefaultFanTemperatureSelection.source }
    var defaultFanTemperatureSensorKey: String? {
        if let rule = activeBuiltinThermalRule { return rule.sensorKey }
        return savedDefaultFanTemperatureSelection.sensorKey
    }
    private var savedDefaultFanTemperatureSelection: DefaultFanTemperatureSelection
    var fanPresets: [FanPreset] = [] {
        didSet {
            // 已识别为用户方案的 ID 即使后来被删除，也不能重新被旧内置规则兼容逻辑认领。
            knownCustomFanPresetIDs.formUnion(fanPresets.map(\.id))
        }
    }
    private var knownCustomFanPresetIDs: Set<UUID> = []
    private var localFanPresetsLoaded = false
    var presetBusy = false
    var targetRPM = 3200.0
    var strategy = "均衡"
    // 仅统一内置方案展示名，保留旧策略值，避免改变已有方案选择与控制参数。
    var strategyTitle: String { strategy == "均衡" ? "日常均衡" : strategy }
    var needsFanAuthorization: Bool { !fanClient.ready }
    var fanServiceActionTitle: String { needsFanAuthorization ? "授权风扇控制" : "重试连接" }

    var fanStatus = FanControlStatus(phase: .system)
    private let fanClient: any FanControlConnection
    private let launchLocalInstaller: (Bool) async throws -> Void
    private let presetStore: FanPresetStore
    private var presetRevision = 0
    private let loadLocalCapabilities: @Sendable () async throws -> [FanCapability]
    private let loadLocalPresets: @Sendable () async throws -> [FanPreset]
    private var localStartupTask: Task<Void, Never>?
    private var receivedServiceCapabilities = false
    private var controlTask: Task<Void, Never>?
    private var controlRevision = 0
    // 仅记住本客户端实际成功应用的完整配置；预设列表和其他连接的状态不作为恢复来源。
    private static let lastAppliedFanPresetKey = "ermi.lastAppliedFanPreset"
    private static let defaultFanTemperatureSelectionKey = "ermi.defaultFanTemperatureSelection"
    private static let balancedFanPresetID = UUID(uuidString: "934731CE-DF92-4ABA-B2FC-6F421CE7C001")!
    private static let coolingFanPresetID = UUID(uuidString: "934731CE-DF92-4ABA-B2FC-6F421CE7C002")!
    // 从固定/系统模式返回时保留已确认规则身份，名称相同的自定义方案不能替代内置方案。
    private var lastConfirmedThermalPreset: FanPreset?
    private struct DefaultFanTemperatureSelection: Codable, Equatable {
        let source: FanTemperatureSource
        let sensorKey: String?
        var isValid: Bool {
            source == .sensor ? sensorKey.map(FanThermalRule.isValidSensorKey) == true : sensorKey == nil
        }
    }
    private var startupRestorePending = true
    private var startupRestoreToken = UUID()
    private var startupApplyTask: Task<Void, Never>?
    private var startupRestoreFailureNotice: String?

    private func cancelStartupRestore(invalidateInFlight: Bool = false) {
        startupRestorePending = false
        // 生命周期结束才废弃在途回包；用户连续切换仍需确认前一次结果，才能串行交还系统。
        if invalidateInFlight {
            startupRestoreToken = UUID()
            // request 授权校验本身会挂起；取消任务可阻止退出后才完成校验的旧请求发送 apply。
            startupApplyTask?.cancel()
            startupApplyTask = nil
        }
        startupRestoreFailureNotice = nil
    }

    // 生命周期与操作版本分开：睡眠/唤醒使整条旧连接的回包失效，不能覆盖新连接状态。
    private var controlEpoch = UUID()
    private var sleeping = false
    var fanControlBadge: String {
        if let pendingFanMode { return pendingFanMode == .system ? "正在交还系统…" : "正在应用…" }
        if controlBusy { return "正在确认…" }
        if fanStatus.phase == .needsRecovery { return "恢复待确认" }
        return fanMode == .auto ? "App 自动温控" : (fanMode == .fixed ? "固定 RPM" : "Ermi 未接管")
    }
    var independentTargets: String? {
        guard case .fixedTargets = fanStatus.preset?.configuration else { return nil }
        return fanStatus.targets.sorted { $0.key < $1.key }.map { "\(Int($0.value))" }.joined(separator: " / ") + " RPM"
    }
    var fanRPMRange: ClosedRange<Double> {
        let low = fanCapabilities.map(\.minimumRPM).max() ?? 2000
        let high = fanCapabilities.map(\.maximumRPM).min() ?? 5000
        return low...max(low + 1, high)
    }
    var feedback = ""
    var isStopping = false
    var isVisible = false
    private let sampler: SystemSampler
    private let signaler: ProcessSignaler
    init(fanClient: any FanControlConnection = FanControlClient(),
         defaults: UserDefaults = .standard,
         loadLocalCapabilities: @escaping @Sendable () async throws -> [FanCapability] = {
             try SMCFanDevice().capabilities()
         },
         loadLocalPresets: (@Sendable () async throws -> [FanPreset])? = nil,
         presetStore: FanPresetStore = FanPresetStore(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ermi/fan-presets.json")),
         launchLocalInstaller: @escaping (Bool) async throws -> Void = { uninstall in
             try await LocalFanInstallerClient.run(uninstall: uninstall)
         }) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultFanTemperatureSelectionKey),
           let selection = try? JSONDecoder().decode(DefaultFanTemperatureSelection.self, from: data), selection.isValid {
            savedDefaultFanTemperatureSelection = selection
        } else {
            // 旧安装没有选源设置时，保持原有 CPU/GPU 较高温度及 50→80/70°C 规则。
            savedDefaultFanTemperatureSelection = .init(source: .maxCPUAndGPU, sensorKey: nil)
        }
        // 缺少设置的旧安装沿用原来的显示行为；显式关闭必须跨启动保留。
        showMenuBarTemperature = defaults.object(forKey: "ermi.showMenuBarTemperature") as? Bool ?? true
        self.fanClient = fanClient
        self.launchLocalInstaller = launchLocalInstaller
        self.loadLocalCapabilities = loadLocalCapabilities
        self.presetStore = presetStore
        let store = presetStore
        self.loadLocalPresets = loadLocalPresets ?? { try await store.load() }
        let sampler = SystemSampler()
        self.sampler = sampler
        self.signaler = ProcessSignaler(sampler: sampler)
        usesLocalFanControl = fanClient.usesLocalMode
        localFanSetupMessage = fanClient.localSetupMessage
    }
    private var task: Task<Void, Never>?

    var processes: [ProcessSample] {
        (snapshot?.processes ?? []).sorted {
            if sortByMemory { return $0.memoryBytes > $1.memoryBytes }
            return ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1)
        }
    }

    // 采样任务只创建一次；退出时取消，窗口开关不再叠加定时器。
    func start() {
        startFanControl()
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.snapshot = await self.sampler.sample(includeTemperatureSensors: self.shouldSampleTemperatureSensors)
                try? await Task.sleep(for: .seconds(self.isVisible ? 2 : 5))
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        invalidateFanSession()
    }

    private func invalidateFanSession() {
        cancelStartupRestore(invalidateInFlight: true)
        controlEpoch = UUID()
        controlRevision += 1
        controlTask?.cancel(); controlTask = nil
        localStartupTask?.cancel(); localStartupTask = nil
        controlBusy = false
        pendingFanMode = nil
        queuedFanMode = nil
        helperReady = false
        fanClient.disconnect()
    }

    func prepareForSleep() async {
        guard !sleeping, !designPreview else { return }
        cancelStartupRestore(invalidateInFlight: true)
        sleeping = true
        let wasBusy = controlBusy
        let wasReady = helperReady
        controlEpoch = UUID()
        let epoch = controlEpoch
        controlRevision += 1
        controlTask?.cancel(); controlTask = nil
        localStartupTask?.cancel(); localStartupTask = nil
        controlBusy = false
        pendingFanMode = nil
        queuedFanMode = nil
        helperReady = false
        // 正在写入时服务会拒绝 restore；断连接让服务端 shutdown 等待写入结束并恢复。
        // 没有确认回包时保留实际状态，绝不把“已断开”显示成“已恢复”。
        guard wasReady, !wasBusy else {
            fanClient.disconnect()
            if fanStatus.phase == .applied || wasBusy {
                controlNotice = "睡眠前已停止续租，等待服务确认恢复系统控制。"
                controlNeedsAttention = true
            }
            return
        }
        do {
            let reply = try await fanClient.request(.restore)
            guard epoch == controlEpoch, sleeping else { return }
            acceptFanReply(reply)
        } catch {
            guard epoch == controlEpoch, sleeping else { return }
            controlNotice = "睡眠恢复尚未确认：\(error.localizedDescription)"
            controlNeedsAttention = true
        }
        // 即使收到“正在控制”的业务错误也断开，不依赖停止运行期间的客户端心跳。
        guard epoch == controlEpoch, sleeping else { return }
        fanClient.disconnect()
    }

    func resumeAfterSleep() {
        guard sleeping else { return }
        sleeping = false
        // 快速唤醒可能早于恢复回包；先废弃旧连接，迟到结果不能断开新会话。
        invalidateFanSession()
        // 每次真实睡眠唤醒都重新获得一次恢复机会；睡前交还系统不代表用户选择了系统模式。
        // 只读取最后成功配置，并沿用首次连接确认、用户操作优先和失败不重试的规则。
        startupRestorePending = true
        startFanControl()
    }

    private func startFanControl() {
        guard controlTask == nil, !designPreview, !sleeping else { return }
        let epoch = controlEpoch
        receivedServiceCapabilities = false
        let capabilitiesLoader = loadLocalCapabilities
        let presetsLoader = loadLocalPresets
        let startupPresetRevision = presetRevision
        // 本地读取与服务握手互不依赖；脱离主 actor 执行，慢磁盘/SMC 不能阻塞首次连接。
        // 本地能力仅供未授权时编辑预设，服务确认的能力优先，迟到结果不能覆盖它。
        localStartupTask = Task { [weak self] in
            let capabilitiesTask = Task.detached { try? await capabilitiesLoader() }
            let presetsTask = Task.detached { () -> Result<[FanPreset], Error> in
                do { return .success(try await presetsLoader()) }
                catch { return .failure(error) }
            }
            await withTaskCancellationHandler {
                let capabilities = await capabilitiesTask.value
                guard let self, epoch == self.controlEpoch, !Task.isCancelled else { return }
                if !self.receivedServiceCapabilities {
                    if let capabilities {
                        self.fanCapabilities = capabilities
                        self.isFanless = capabilities.isEmpty
                        self.fanCapabilityIssue = capabilities.isEmpty ? "此 Mac 没有风扇，无需调速。" : nil
                    } else {
                        self.isFanless = false
                        self.fanCapabilityIssue = "风扇控制能力暂不可用，请重试连接。"
                    }
                }
                let presets = await presetsTask.value
                guard epoch == self.controlEpoch, !Task.isCancelled else { return }
                // 连接期间用户可能已经保存或删除预设，旧磁盘快照不能覆盖较新的编辑结果。
                guard startupPresetRevision == self.presetRevision else { return }
                switch presets {
                case .success(let presets):
                    self.fanPresets = presets
                    self.localFanPresetsLoaded = true
                case .failure(let error):
                    // 后台预设失败不能遮盖授权操作或已经出现的控制错误。
                    if !self.installerOpening && !self.controlBusy && !self.controlNeedsAttention {
                        self.controlNotice = error.localizedDescription; self.controlNeedsAttention = true
                    }
                }
            } onCancel: {
                capabilitiesTask.cancel()
                presetsTask.cancel()
            }
        }
        controlTask = Task { [weak self] in
            guard let self else { return }
            var inspectedService = false
            while !Task.isCancelled && epoch == controlEpoch && !sleeping {
                // 安装或卸载期间服务可能重启，轮询暂停，避免连接错误覆盖系统授权反馈。
                if installerOpening {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                do {
                    let revision = controlRevision
                    // request 本身校验当前授权并更新 ready；同一轮不再重复做完整校验。
                    // 首次必须 inspect，不能把本地读到能力误认为服务握手已完成。
                    let reply = try await fanClient.request(inspectedService ? .heartbeat : .inspect)
                    guard epoch == controlEpoch, !Task.isCancelled else { return }
                    usesLocalFanControl = fanClient.usesLocalMode
                    localFanSetupMessage = fanClient.localSetupMessage
                    guard !installerOpening else { continue }
                    helperReady = true
                    if revision == controlRevision && !controlBusy {
                        // 失败的自动恢复需要用户处理，普通 system 心跳不能立即抹掉错误提示。
                        let retainedNotice = startupRestoreFailureNotice
                        acceptFanReply(reply)
                        if let retainedNotice, reply.error == nil, reply.status.phase == .system {
                            controlNotice = retainedNotice
                            controlNeedsAttention = true
                        }
                        inspectedService = true
                        restoreStartupConfigurationIfNeeded(after: reply)
                    }
                } catch {
                    guard epoch == controlEpoch, !Task.isCancelled else { return }
                    usesLocalFanControl = fanClient.usesLocalMode
                    localFanSetupMessage = fanClient.localSetupMessage
                    guard !installerOpening else { continue }
                    helperReady = false
                    // 未授权保持原来的授权入口提示，只有已有授权的连接故障才报错。
                    if fanClient.ready {
                        controlNotice = "控制连接不可用：\(error.localizedDescription)"; controlNeedsAttention = true
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func enableFanControl() async {
        cancelStartupRestore()
        guard !designPreview, !controlBusy, !installerOpening, !sleeping else { return }
        let refreshEpoch = controlEpoch
        do { try await fanClient.refreshAvailability() }
        catch {
            guard refreshEpoch == controlEpoch, !sleeping else { return }
            controlNotice = error.localizedDescription; controlNeedsAttention = true; return
        }
        guard refreshEpoch == controlEpoch, !sleeping, !controlBusy, !installerOpening else { return }
        // 本机临时签名必须先安装当前构建的授权，不能只尝试连接后留下错误文字。
        if fanClient.usesLocalMode && !fanClient.ready {
            openLocalFanInstaller()
            return
        }
        let epoch = controlEpoch
        controlBusy = true; defer { if epoch == controlEpoch { controlBusy = false } }
        do {
            try await fanClient.enable()
            let reply = try await fanClient.request(.inspect)
            guard epoch == controlEpoch, !sleeping else { return }
            acceptFanReply(reply)
            helperReady = true

        } catch {
            guard epoch == controlEpoch, !sleeping else { return }
            helperReady = false; controlNotice = error.localizedDescription; controlNeedsAttention = true
        }
    }
    func openLocalFanInstaller(uninstall: Bool = false) {
        cancelStartupRestore()
        guard !designPreview, !controlBusy, !sleeping, !installerOpening else { return }
        installerOpening = true
        controlRevision += 1
        controlNeedsAttention = false
        controlNotice = uninstall ? "请在系统窗口确认卸载…" : "请在系统窗口确认安装…"
        let epoch = controlEpoch
        Task {
            // 等待管理员验证期间保持界面响应且禁止重复安装；睡眠后不得重放安装结果或控制请求。
            defer { installerOpening = false }
            do {
                try await launchLocalInstaller(uninstall)
                guard epoch == controlEpoch, !sleeping else { return }
                fanClient.disconnect()
                helperReady = false
                if uninstall {
                    controlNotice = "本机风扇服务已卸载，预设已保留。"
                    controlNeedsAttention = false
                    return
                }
                // 安装成功只重新连接并读取状态，不调用会再次安装的 enableFanControl，也不应用旧选择。
                try await fanClient.enable()
                let reply = try await fanClient.request(.inspect)
                guard epoch == controlEpoch, !sleeping else { return }
                acceptFanReply(reply)
                helperReady = true
            } catch LocalFanInstallerError.cancelled {
                guard epoch == controlEpoch, !sleeping else { return }
                controlNotice = uninstall ? "已取消卸载。" : "已取消安装。"
                controlNeedsAttention = false
            } catch {
                guard epoch == controlEpoch, !sleeping else { return }
                controlNotice = "授权操作未完成：\(error.localizedDescription)"
                controlNeedsAttention = true
            }
        }
    }

    func selectFanMode(_ mode: FanMode) {
        cancelStartupRestore()
        if designPreview { fanMode = mode; return }
        guard mode == .system || canApplyFanControl else {
            controlNotice = fanCapabilityIssue ?? "设备控制能力暂不可用"; controlNeedsAttention = true; return
        }
        // 连续切换只保留最后一次选择，硬件请求仍串行；授权、睡眠和失败路径不排队重放。
        if controlBusy, pendingFanMode != nil, helperReady, !sleeping {
            queuedFanMode = mode
            pendingFanMode = mode
            return
        }
        guard prepareExplicitFanControl() else { return }
        if mode == .system {
            // 在创建任务前占用操作，避免下一次点击插入恢复请求；旧生命周期不得清理新请求。
            let epoch = controlEpoch
            pendingFanMode = .system
            controlBusy = true
            Task {
                defer { if epoch == controlEpoch { finishFanSelection() } }
                guard epoch == controlEpoch, !sleeping else { return }
                await restoreFanControl(clearRememberedConfiguration: true)
            }
            return
        }
        if mode == .fixed { applyFixedRPM(); return }
        // 返回自动模式按已确认身份恢复；内置方案共用保存来源，自定义方案保留自身完整规则。
        if let previous = lastConfirmedThermalPreset, previous.name == strategy {
            if let name = builtinPresetName(for: previous) { applyFanPreset(builtinFanPreset(named: name)) }
            else if let preset = fanPresets.first(where: { $0.id == previous.id }), case .thermal = preset.configuration {
                applyFanPreset(preset)
            } else {
                // 删除方案或将其改为固定转速后，返回自动必须回到均衡，不能重放已删除或非温控规则。
                strategy = "均衡"
                applyFanPreset(builtinFanPreset(named: strategy))
            }
            return
        }
        if let preset = fanPresets.first(where: { $0.name == strategy }), case .thermal = preset.configuration {
            applyFanPreset(preset); return
        }
        if strategy != "积极散热" { strategy = "均衡" }
        applyFanPreset(builtinFanPreset(named: strategy))
    }
    func builtinFanPreset(named name: String) -> FanPreset {
        // 切换内置曲线沿用当前显示且已确认的来源；外部回读只影响本次构造，显式应用成功才保存。
        let selection = activeBuiltinThermalRule.map { DefaultFanTemperatureSelection(source: $0.sensor, sensorKey: $0.sensorKey) }
            ?? savedDefaultFanTemperatureSelection
        return builtinFanPreset(named: name, selection: selection)
    }
    private func builtinFanPreset(named name: String, selection: DefaultFanTemperatureSelection) -> FanPreset {
        let cooling = name == "积极散热"
        return FanPreset(id: cooling ? Self.coolingFanPresetID : Self.balancedFanPresetID,
                         name: cooling ? "积极散热" : "均衡",
                         configuration: .thermal(.init(sensor: selection.source, lowerTemperature: 50,
                                                       upperTemperature: cooling ? 70 : 80, sensorKey: selection.sensorKey)))
    }
    func isBuiltinFanPreset(_ preset: FanPreset) -> Bool { builtinPresetName(for: preset) != nil }
    private func builtinPresetName(for preset: FanPreset) -> String? {
        guard !knownCustomFanPresetIDs.contains(preset.id),
              preset.name == "均衡" || preset.name == "积极散热", case .thermal(let rule) = preset.configuration,
              rule.lowerTemperature == 50, rule.upperTemperature == (preset.name == "积极散热" ? 70 : 80),
              rule.lowerRPM == nil, rule.upperRPM == nil, rule.rampRPMPerSecond == nil else { return nil }
        let expectedID = preset.name == "积极散热" ? Self.coolingFanPresetID : Self.balancedFanPresetID
        // 新内置方案用稳定 ID；旧版随机 ID 必须等本地列表成功读取、排除用户方案后再兼容。
        // 启动恢复可早于磁盘读取，未知期间不能把同名同规则的用户方案当内置并覆盖来源偏好。
        guard preset.id == expectedID || (localFanPresetsLoaded && rule.sensor == .maxCPUAndGPU && rule.sensorKey == nil) else { return nil }
        return preset.name
    }
    private var activeBuiltinThermalRule: FanThermalRule? {
        guard fanStatus.phase == .applied, let preset = fanStatus.preset, isBuiltinFanPreset(preset),
              case .thermal(let rule) = preset.configuration else { return nil }
        return rule
    }
    func selectDefaultFanTemperatureSource(_ source: FanTemperatureSource, sensorKey: String? = nil) {
        guard !designPreview, !controlBusy, !installerOpening, !sleeping else { return }
        let selection = DefaultFanTemperatureSelection(source: source, sensorKey: source == .sensor ? sensorKey : nil)
        guard selection.isValid else {
            controlNotice = "请选择有效的温度传感器。"; controlNeedsAttention = true; return
        }
        cancelStartupRestore()
        if fanStatus.phase == .applied, let preset = fanStatus.preset, let name = builtinPresetName(for: preset) {
            // 正在运行的内置方案必须经过既有能力检查和 helper 确认，失败时保存来源保持不变。
            applyFanPreset(builtinFanPreset(named: name, selection: selection))
        } else {
            // 系统、固定转速或自定义方案中只设置下次内置方案的来源，不写硬件、不改自定义规则。
            persistDefaultFanTemperatureSelection(selection)
        }
    }
    private func persistDefaultFanTemperatureSelection(_ selection: DefaultFanTemperatureSelection) {
        guard selection.isValid, let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: Self.defaultFanTemperatureSelectionKey)
        savedDefaultFanTemperatureSelection = selection
    }
    func applyFixedRPM() {
        applyFanPreset(FanPreset(name: "固定转速", configuration: .fixed(rpm: targetRPM)))
    }
    // 未连接时，显式点击只发起授权/连接，不缓存或自动重放用户的硬件写入。
    // 睡眠、退出等自动恢复路径不调用此入口，避免在后台弹出授权。
    private func prepareExplicitFanControl() -> Bool {
        guard !controlBusy, !installerOpening, !designPreview, !sleeping else { return false }
        guard helperReady else {
            let epoch = controlEpoch
            Task {
                guard epoch == controlEpoch, !sleeping else { return }
                await enableFanControl()
            }
            return false
        }
        return true
    }
    func applyFanPreset(_ preset: FanPreset) {
        cancelStartupRestore()
        guard canApplyFanControl else {
            controlNotice = fanCapabilityIssue ?? "设备控制能力暂不可用"; controlNeedsAttention = true; return
        }
        guard prepareExplicitFanControl() else { return }
        beginApplyingFanPreset(preset, restoringStartup: false)
    }

    private func restoreStartupConfigurationIfNeeded(after reply: FanServiceReply) {
        guard startupRestorePending, reply.error == nil else { return }
        // 首个成功回包只决策一次：其他控制者或恢复故障存在时绝不等其变为 system 再接管。
        startupRestorePending = false
        guard canApplyFanControl, reply.status.phase == .system, !controlBusy, !installerOpening, !sleeping,
              let data = defaults.data(forKey: Self.lastAppliedFanPresetKey),
              let preset = try? JSONDecoder().decode(FanPreset.self, from: data) else { return }
        // 直接复用已连接的 apply；helper 仍对当前硬件能力与参数完整校验，不触发授权安装。
        beginApplyingFanPreset(preset, restoringStartup: true)
    }

    private func beginApplyingFanPreset(_ preset: FanPreset, restoringStartup: Bool) {
        // 旧服务不理解具体传感器；显式阻止提交，也覆盖启动时恢复上次方案的路径。
        if case .thermal(let rule) = preset.configuration, rule.sensor == .sensor, !supportsTemperatureSensorSelection {
            controlNotice = "当前风扇服务不支持自定义传感器，请先安装 / 更新授权。"
            controlNeedsAttention = true
            if restoringStartup { startupRestoreFailureNotice = controlNotice }
            return
        }
        controlRevision += 1
        controlBusy = true
        switch preset.configuration {
        case .thermal: pendingFanMode = .auto
        case .fixed, .fixedTargets: pendingFanMode = .fixed
        }
        let epoch = controlEpoch
        let restoreToken = startupRestoreToken
        let applicationTask = Task {
            defer { if epoch == controlEpoch { finishFanSelection() } }
            // 点击后任务可能尚未执行就收到睡眠通知；旧任务不得建立新连接并重新接管。
            guard epoch == controlEpoch, !sleeping,
                  !restoringStartup || restoreToken == startupRestoreToken else { return }
            do {
                let reply = try await fanClient.request(.apply(preset))
                guard epoch == controlEpoch, !sleeping,
                  !restoringStartup || restoreToken == startupRestoreToken else { return }
                acceptFanReply(reply)
                // 只有回包明确确认同一完整配置才持久化，错误或不匹配回包不能替换上次成功记录。
                let confirmed = reply.error == nil && reply.status.phase == .applied && reply.status.preset == preset
                if confirmed, let data = try? JSONEncoder().encode(preset) {
                    defaults.set(data, forKey: Self.lastAppliedFanPresetKey)
                    if isBuiltinFanPreset(preset), case .thermal(let rule) = preset.configuration {
                        persistDefaultFanTemperatureSelection(.init(source: rule.sensor, sensorKey: rule.sensorKey))
                    }
                }
                if restoringStartup && !confirmed {
                    if !controlNeedsAttention {
                        controlNotice = "设备控制能力暂不可用"
                        controlNeedsAttention = true
                    }
                    startupRestoreFailureNotice = controlNotice
                }
            } catch {
                guard epoch == controlEpoch, !sleeping,
                  !restoringStartup || restoreToken == startupRestoreToken else { return }
                controlNotice = error.localizedDescription; controlNeedsAttention = true; fanClient.disconnect()
                if restoringStartup { startupRestoreFailureNotice = controlNotice }
            }
        }
        if restoringStartup { startupApplyTask = applicationTask }
    }
    private func finishFanSelection() {
        let next = queuedFanMode
        queuedFanMode = nil
        pendingFanMode = nil
        controlBusy = false
        // 只有前一次设备确认成功才能继续；异常时保留错误并放弃后续硬件操作。
        if !controlNeedsAttention, let next, next != fanMode { selectFanMode(next) }
    }
    func saveFanPreset(_ preset: FanPreset) async -> String {
        guard !designPreview else { return "演示：预设已保存" }
        guard !presetBusy else { return "正在保存方案，请稍候。" }
        presetBusy = true
        defer { presetBusy = false }
        do {
            // Store 按稳定 ID 原位更新，并在落盘前拒绝重名；不会删除另一份用户方案。
            fanPresets = try await presetStore.upsert(preset)
            localFanPresetsLoaded = true
            presetRevision += 1
            return "已保存预设，点击应用后生效。"
        } catch { return error.localizedDescription }
    }
    func deleteFanPreset(_ preset: FanPreset) async -> String {
        guard !designPreview else { return "演示：不会删除本机方案。" }
        guard !presetBusy else { return "正在保存方案，请稍候。" }
        presetBusy = true
        defer { presetBusy = false }
        do {
            // 删除只改持久化列表；正在运行的配置仍由 helper 持有，不自动恢复或改写风扇。
            let remaining = try await presetStore.remove(id: preset.id)
            fanPresets = remaining
            localFanPresetsLoaded = true
            presetRevision += 1
            return "已删除“\(preset.name)”，当前风扇运行不变。"
        } catch { return "删除失败：\(error.localizedDescription)" }
    }
    // 只在 helper 回读后更新已确认模式；请求中的界面选中态独立，实际 RPM 来自监控采样。
    private func acceptFanReply(_ reply: FanServiceReply) {
        if reply.capabilityProbeCompleted == true || !reply.capabilities.isEmpty {
            supportsTemperatureSensorSelection = reply.supportsTemperatureSensorSelection == true
        }
        // heartbeat 的默认空数组不代表无风扇；只有 inspect 的明确标记可以清空旧能力。
        // 旧 helper 的非空能力仍兼容，探测错误保留至下一次有效探测，防止心跳重新开放写入。
        if reply.capabilityProbeCompleted == true || !reply.capabilities.isEmpty {
            receivedServiceCapabilities = true
            fanCapabilities = reply.capabilities
            isFanless = reply.error == nil && reply.capabilities.isEmpty
            fanCapabilityIssue = reply.error ?? (reply.capabilities.isEmpty ? "此 Mac 没有风扇，无需调速。" : nil)
        }
        if let error = reply.error { controlNotice = error; controlNeedsAttention = true; return }
        // 正常回读信息不遮住快捷控件；只有真实故障替换为详情入口。
        controlNeedsAttention = reply.status.phase == .failed || reply.status.phase == .needsRecovery
        let changedPreset = fanStatus.preset?.id != reply.status.preset?.id
        fanStatus = reply.status
        switch reply.status.phase {
        case .system: fanMode = .system; controlNotice = "Ermi 未接管风扇控制。"
        case .applied:
            if let preset = reply.status.preset {
                switch preset.configuration {
                case .thermal:
                    fanMode = .auto; strategy = preset.name
                    lastConfirmedThermalPreset = preset
                case .fixed(let rpm):
                    fanMode = .fixed
                    if changedPreset { targetRPM = rpm }
                case .fixedTargets: fanMode = .fixed
                }
                controlNotice = "已确认目标转速 · \(preset.name == "均衡" ? "日常均衡" : preset.name)"
            }
        case .failed: fanMode = .system; controlNotice = reply.status.message ?? "控制失败，已恢复系统控制"
        case .needsRecovery: controlNotice = reply.status.message ?? "系统控制尚未确认，正在重试恢复"
        }
        if let issue = fanCapabilityIssue, reply.status.phase == .system {
            controlNotice = issue
            controlNeedsAttention = true
        }
    }
    func restoreFanControl(clearRememberedConfiguration: Bool = false) async {
        guard !designPreview else { fanMode = .system; return }
        guard helperReady, !sleeping else { return }
        let epoch = controlEpoch
        controlRevision += 1
        do {
            let reply = try await fanClient.request(.restore)
            guard epoch == controlEpoch, !sleeping else { return }
            acceptFanReply(reply)
            // 主动选系统自动才清除记忆；睡眠和退出的临时交还必须保留下一次启动配置。
            if clearRememberedConfiguration, reply.error == nil, reply.status.phase == .system {
                defaults.removeObject(forKey: Self.lastAppliedFanPresetKey)
            }
        } catch {
            guard epoch == controlEpoch, !sleeping else { return }
            controlNotice = "恢复尚未确认：\(error.localizedDescription)"; controlNeedsAttention = true; fanClient.disconnect()
        }
    }
    func prepareForExit() async -> Bool {
        cancelStartupRestore(invalidateInFlight: true)
        // 迟到的应用任务仍会执行收尾，退出时必须丢弃排队选择，防止交还系统后再次接管。
        queuedFanMode = nil
        controlTask?.cancel(); controlTask = nil
        localStartupTask?.cancel(); localStartupTask = nil
        await restoreFanControl()
        return fanStatus.phase == .system || fanStatus.phase == .failed
    }

    func end(_ process: ProcessSample, force: Bool) async {
        guard !isStopping, !designPreview else { return }
        isStopping = true
        defer { isStopping = false }
        // 普通进程与 App 共用内核身份和祖先保护校验，不依赖可能过期的界面列表。
        do { try await signaler.validate(process: process) }
        catch { feedback = "无法结束：\(error.localizedDescription)"; return }
        let accepted: Bool
        if let app = NSRunningApplication(processIdentifier: process.id.pid) {
            accepted = force ? app.forceTerminate() : app.terminate()
        } else {
            // libproc 列表仅包含当前用户进程；系统仍执行信号权限检查。
            do { try await signaler.send(process: process, force: force); accepted = true }
            catch { feedback = "无法结束：\(error.localizedDescription)"; return }
        }
        guard accepted else { feedback = "操作未被接受，可能没有权限或进程已退出。"; return }
        // 请求成功不等于退出成功；等候有限时间后报告实际观察结果。
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if await sampler.identity(for: process.id.pid) != process.id {
                feedback = "已结束 \(process.name)"
                snapshot = await sampler.sample()
                return
            }
        }
        feedback = "已发送退出请求，\(process.name) 仍在运行。"
    }
}
