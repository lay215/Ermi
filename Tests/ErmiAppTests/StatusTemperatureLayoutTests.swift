import AppKit
import Testing
@testable import Ermi
@testable import ErmiCore

@MainActor struct StatusTemperatureLayoutTests {
    @Test func popupSummaryUsesCPUTemperatureInsteadOfCPUUsage() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        model.selectDefaultFanTemperatureSource(.cpu)
        // 复现截图：54 是使用率，70 才是 CPU 温度；左右温度必须来自同一轮推荐映射。
        model.snapshot = temperatureSnapshot(cpu: 70.1, gpu: 68.2, cpuPercent: 54)
        #expect(model.panelTemperatureText == "70")
        #expect(model.cpuText == "54")
        #expect(model.panelTemperatureSummary == "CPU 70°C · GPU 68°C")
        model.snapshot = temperatureSnapshot(cpu: 72.8, gpu: 66.1, cpuPercent: 12)
        #expect(model.panelTemperatureText == "73")
        #expect(model.panelTemperatureSummary == "CPU 73°C · GPU 66°C")
        model.selectDefaultFanTemperatureSource(.gpu)
        #expect(model.panelTemperatureText == "66")
        #expect(model.panelTemperatureSummary == "CPU 73°C · GPU 66°C")
        model.snapshot = temperatureSnapshot(cpu: nil, gpu: nil, cpuPercent: 54)
        #expect(model.panelTemperatureText == "—")
        #expect(model.panelTemperatureSummary == "CPU —°C · GPU —°C")
    }

    @Test func appliedCPUSelectionOverridesSavedGPUForPopup() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        model.selectDefaultFanTemperatureSource(.cpu)
        let cpuPreset = model.builtinFanPreset(named: "均衡")
        model.selectDefaultFanTemperatureSource(.gpu)
        // 服务已确认 CPU 方案时，弹窗与选择器应同时使用 CPU，而不是旧 GPU 偏好或两者最高值。
        model.fanStatus = .init(phase: .applied, preset: cpuPreset)
        model.snapshot = temperatureSnapshot(cpu: 51, gpu: 86)
        #expect(model.defaultFanTemperatureSource == .cpu)
        #expect(model.panelTemperatureSourceTitle == "CPU")
        #expect(model.panelTemperatureText == "51")
        #expect(model.gpuTemperatureText == "86")
        model.snapshot = temperatureSnapshot(cpu: nil, gpu: 86)
        #expect(model.panelTemperatureText == "—")
    }

    private func temperatureSnapshot(cpu: Double? = 61.2, gpu: Double? = 84.6,
                                     sensors: [TemperatureSensorReading] = [], cpuPercent: Double? = nil) -> SystemSnapshot {
        .init(timestamp: Date(), cpuPercent: cpuPercent, memory: nil, processes: [], history: [], logicalCPUCount: 1,
              thermalState: .nominal, hardware: .init(deviceModel: "Test Mac",
                cpuTemperature: cpu.map { .init(celsius: $0, sensorKeys: ["TC0P"], aggregation: "test CPU mapping") },
                gpuTemperature: gpu.map { .init(celsius: $0, sensorKeys: ["TG0D"], aggregation: "test GPU mapping") },
                fans: [], source: "test", temperatureSensors: sensors))
    }

    @Test func popupTemperatureFollowsSelectionAndCPUChoiceReturnsToMappedCPU() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        // 故意令 CPU、GPU 与具体键温度不同，验证弹窗读的是选择来源而非固定 CPU 或最高候选。
        model.snapshot = temperatureSnapshot(sensors: [.init(key: "Tp01", celsius: 42.7), .init(key: "Tp02", celsius: 99)])
        #expect(model.panelTemperatureText == "85")
        model.selectDefaultFanTemperatureSource(.gpu)
        #expect(model.panelTemperatureText == "85")
        #expect(model.temperatureHelp.contains("TG0D"))
        #expect(!model.temperatureHelp.contains("TC0P"))
        model.selectDefaultFanTemperatureSource(.sensor, sensorKey: "Tp01")
        #expect(model.panelTemperatureText == "43")
        #expect(model.temperatureHelp.contains("Tp01"))
        model.selectDefaultFanTemperatureSource(.cpu)
        #expect(model.panelTemperatureText == "61")
        #expect(model.panelTemperatureCelsius == 61.2)
        #expect(model.panelTemperatureSourceTitle == "CPU")
        #expect(model.temperatureHelp.contains("TC0P"))
        #expect(!model.temperatureHelp.contains("Tp01"))
        // 仅弹窗主温度联动；概览与菜单栏依赖的推荐映射值仍保持各自 CPU/GPU 含义。
        #expect(model.cpuTemperatureText == "61")
        #expect(model.gpuTemperatureText == "85")
        #expect(model.snapshot?.hardware.cpuTemperature?.celsius == 61.2)
    }

    @Test func popupUnavailableSourceDoesNotReuseAnotherSourceOrPreviousValue() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        model.selectDefaultFanTemperatureSource(.sensor, sensorKey: "Tp01")
        model.snapshot = temperatureSnapshot(sensors: [.init(key: "Tp01", celsius: 72)])
        #expect(model.panelTemperatureText == "72")
        model.snapshot = temperatureSnapshot(sensors: [.init(key: "Tp02", celsius: 99)])
        #expect(model.panelTemperatureText == "—")
        for invalid in [0.0, -1, 151, .nan, .infinity] {
            model.snapshot = temperatureSnapshot(sensors: [.init(key: "Tp01", celsius: invalid)])
            #expect(model.panelTemperatureCelsius == nil)
        }
        model.snapshot = temperatureSnapshot(gpu: nil)
        model.selectDefaultFanTemperatureSource(.maxCPUAndGPU)
        #expect(model.panelTemperatureText == "—")
        model.selectDefaultFanTemperatureSource(.cpu)
        #expect(model.panelTemperatureText == "61")
        model.selectDefaultFanTemperatureSource(.gpu)
        #expect(model.panelTemperatureText == "—")
    }

    @Test func preferencePersistsAndImmediatelyRefreshesStatusItem() throws {
        let suite = "app.ermi.temperature.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        #expect(model.showMenuBarTemperature)
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        button.image = NSImage(size: NSSize(width: 19, height: 19))
        var updates = 0
        model.onSnapshot = { [weak model] _ in
            guard let model else { return }
            updates += 1
            AppDelegate.configureTemperatureLayout(item, showTemperature: model.showMenuBarTemperature, temperature: 73)
        }
        // 复用生产回调，证明切换无需等待采样；关闭态后续采样也不会恢复标题。
        model.showMenuBarTemperature = false
        #expect(updates == 1)
        #expect(button.title.isEmpty)
        #expect(item.length == 24)
        #expect(!MonitorModel(defaults: defaults).showMenuBarTemperature)
        model.onSnapshot?(nil)
        #expect(button.title.isEmpty)
        model.showMenuBarTemperature = true
        #expect(button.title == " 73°")
        let width = item.length
        #expect(width > 0)
        #expect(MonitorModel(defaults: defaults).showMenuBarTemperature)
        AppDelegate.configureTemperatureLayout(item, temperature: nil)
        #expect(button.title == " —°")
        #expect(item.length == width)
        AppDelegate.configureTemperatureLayout(item, temperature: 100)
        #expect(button.title == " 100°")
        #expect(item.length == width)
    }

    @Test func temperatureChangesKeepAllocatedWidthAndFit() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        button.image = NSImage(size: NSSize(width: 19, height: 19))
        AppDelegate.configureTemperatureLayout(item)
        let reservedWidth = item.length
        // 使用真实状态栏按钮测量：数字变化、跨位数、未知与恢复都不能挤动相邻入口。
        #expect(reservedWidth > 0)
        for title in [" —°", " 0°", " 9°", " 10°", " 51°", " 59°", " 61°", " 99°", " 100°", " 150°", " —°", " 59°"] {
            button.title = title
            #expect(item.length == reservedWidth)
            #expect(button.cell!.cellSize.width <= reservedWidth)
        }
        button.title = " 51°"
        let first = button.cell!.cellSize.width
        button.title = " 59°"
        #expect(abs(button.cell!.cellSize.width - first) < 0.01)
    }
}
