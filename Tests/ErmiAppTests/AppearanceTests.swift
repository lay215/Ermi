import Foundation
import Testing
@testable import Ermi

@MainActor struct AppearanceTests {
    @Test func defaultsAndCustomColorsSurviveReload() {
        let name = "app.ermi.theme.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = ErmiAppearance(defaults: defaults)
        #expect(first.preset == .glacier)
        first.preset = .custom
        first.customBackground = 0xfedcba
        first.customAccent = 0xabcdef
        let second = ErmiAppearance(defaults: defaults)
        #expect(second.preset == .custom)
        #expect(second.palette.background == 0xfedcba)
        #expect(second.palette.accent == 0xabcdef)
        defaults.set("unknown", forKey: "ermi.theme")
        #expect(ErmiAppearance(defaults: defaults).preset == .glacier)
    }

    @Test func textContrastAcrossCustomBrightness() {
        // 遍历自定义灰阶及六套主题，验证浅色强调和中间亮度不会导致白字不可读。
        let palettes = (0...255).map { value in
            ErmiPalette(background: UInt32(value * 0x010101), accent: UInt32(value * 0x010101))
        } + ErmiAppearancePreset.allCases.map(\.palette)
        for palette in palettes {
            let a = ErmiPalette.luminance(palette.background)
            let b = ErmiPalette.luminance(palette.header)
            #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
            #expect(1.05 / (ErmiPalette.luminance(palette.readableAccent) + 0.05) >= 4.5)
        }
    }
}
