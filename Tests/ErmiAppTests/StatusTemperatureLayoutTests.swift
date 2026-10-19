import AppKit
import Testing
@testable import Ermi

@MainActor struct StatusTemperatureLayoutTests {
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
        #expect(item.length == NSStatusItem.squareLength)
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
