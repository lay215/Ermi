import AppKit
import SwiftUI
import Observation

struct ErmiPalette: Equatable {
    let background: UInt32
    let accent: UInt32
    // 用 WCAG 相对亮度选字色，自定义浅色也不能沿用白字。
    static func luminance(_ hex: UInt32) -> Double {
        let values = [16, 8, 0].map { shift -> Double in
            let value = Double((hex >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
    // 内容区将背景与白色混合，统一色相并保证所有预设、自定义深色下正文仍可读。
    func surface(white: Double) -> UInt32 {
        let rgb = [16, 8, 0].map { shift in
            UInt32((Double((background >> shift) & 255) * (1 - white) + 255 * white).rounded())
        }
        return (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]
    }
    var header: UInt32 {
        let light = Self.luminance(background)
        if 1.05 / (light + 0.05) >= 4.5 { return 0xffffff }
        if (light + 0.05) / (Self.luminance(0x152334) + 0.05) >= 4.5 { return 0x152334 }
        return 0x000000
    }
    var readableAccent: UInt32 {
        var value = accent
        // 选中按钮保持白字；用户选的浅强调色逐级加深至至少 4.5:1。
        while Self.luminance(value) > 0.183 {
            let rgb = [16, 8, 0].map { UInt32(Double((value >> $0) & 255) * 0.9) }
            value = (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]
        }
        return value
    }
}

enum ErmiAppearancePreset: String, CaseIterable, Identifiable {
    case glacier, graphite, midnight, pine, stone, lavender, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glacier: "冰川银"
        case .graphite: "石墨灰"
        case .midnight: "午夜蓝"
        case .pine: "雾松绿"
        case .stone: "暖岩灰"
        case .lavender: "薰衣草灰"
        case .custom: "自定义"
        }
    }
    var palette: ErmiPalette {
        switch self {
        case .glacier, .custom: .init(background: 0xe8edf2, accent: 0x486079)
        case .graphite: .init(background: 0x292c33, accent: 0x444a56)
        case .midnight: .init(background: 0x18243c, accent: 0x30476d)
        case .pine: .init(background: 0x29413b, accent: 0x3e6256)
        case .stone: .init(background: 0x4b4542, accent: 0x6d6055)
        case .lavender: .init(background: 0xe5e1ee, accent: 0x625875)
        }
    }
}

@MainActor @Observable
final class ErmiAppearance {
    static let shared = ErmiAppearance()
    private let defaults: UserDefaults
    var preset: ErmiAppearancePreset { didSet { defaults.set(preset.rawValue, forKey: "ermi.theme") } }
    var customBackground: UInt32 { didSet { defaults.set(Int(customBackground), forKey: "ermi.theme.background") } }
    var customAccent: UInt32 { didSet { defaults.set(Int(customAccent), forKey: "ermi.theme.accent") } }
    var previewPreset: ErmiAppearancePreset?
    var palette: ErmiPalette {
        if let previewPreset { return previewPreset.palette }
        return preset == .custom ? .init(background: customBackground, accent: customAccent) : preset.palette
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preset = ErmiAppearancePreset(rawValue: defaults.string(forKey: "ermi.theme") ?? "") ?? .glacier
        func color(_ key: String, fallback: UInt32) -> UInt32 {
            guard let value = defaults.object(forKey: key) as? NSNumber,
                  (0...0xffffff).contains(value.intValue) else { return fallback }
            return UInt32(value.intValue)
        }
        customBackground = color("ermi.theme.background", fallback: 0xe8edf2)
        customAccent = color("ermi.theme.accent", fallback: 0x486079)
    }
    static func hex(_ color: Color) -> UInt32? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return UInt32((rgb.redComponent * 255).rounded()) << 16
            | UInt32((rgb.greenComponent * 255).rounded()) << 8
            | UInt32((rgb.blueComponent * 255).rounded())
    }
}

struct AppearanceSettings: View {
    @Bindable private var appearance = ErmiAppearance.shared
    private var selectedPreset: ErmiAppearancePreset { appearance.previewPreset ?? appearance.preset }
    var body: some View {
        VStack(spacing: 0) {
            SettingsRow("配色方案", description: "统一菜单栏面板、详情页与弹层的颜色") {
                HStack(spacing: 4) {
                    ForEach(ErmiAppearancePreset.allCases.filter { $0 != .custom }) { preset in
                        Button {
                            appearance.previewPreset = nil
                            appearance.preset = preset
                        } label: {
                            Circle().fill(Color(hex: preset.palette.background)).frame(width: 12, height: 12)
                                .padding(2)
                                .overlay(Circle().stroke(selectedPreset == preset ? ErmiTheme.link : ErmiTheme.detailLine, lineWidth: selectedPreset == preset ? 1.5 : 0.5))
                        }.buttonStyle(.plain).help(L(preset.title)).accessibilityLabel(L(preset.title))
                    }
                }
                DetailMenu(title: "配色方案", selection: Binding(
                    get: { selectedPreset },
                    set: { appearance.previewPreset = nil; appearance.preset = $0 }
                ), options: ErmiAppearancePreset.allCases.map { ($0, $0.title) })
                    .frame(width: 90)
            }
            SettingsDivider()
            SettingsRow("主题预览", description: "背景与强调色的实际搭配", indented: true) {
                Button(L("恢复默认")) { appearance.previewPreset = nil; appearance.preset = .glacier }
                HStack(spacing: 14) {
                    Text("60°C").font(.system(size: 15, weight: .medium)).monospacedDigit()
                    Text(L("自动调节")).font(.system(size: 8)).foregroundStyle(.white).padding(6)
                        .background(Color(hex: appearance.palette.readableAccent), in: RoundedRectangle(cornerRadius: 4))
                }.foregroundStyle(Color(hex: appearance.palette.header)).padding(8)
                    .background(Color(hex: appearance.palette.background), in: RoundedRectangle(cornerRadius: 6))
            }
            // 自定义颜色仍走原有持久化与对比度处理，分组改变不影响颜色来源。
            if appearance.preset == .custom {
                SettingsDivider()
                SettingsRow("面板背景") {
                    ColorPicker(L("面板背景"), selection: Binding(get: { Color(hex: appearance.customBackground) }, set: {
                        if let hex = ErmiAppearance.hex($0) { appearance.customBackground = hex }
                    }), supportsOpacity: false).labelsHidden()
                }
                SettingsDivider()
                SettingsRow("主题强调色") {
                    ColorPicker(L("主题强调色"), selection: Binding(get: { Color(hex: appearance.customAccent) }, set: {
                        if let hex = ErmiAppearance.hex($0) { appearance.customAccent = hex }
                    }), supportsOpacity: false).labelsHidden()
                }
            }
        }
    }
}
