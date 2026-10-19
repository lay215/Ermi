import AppKit
import SwiftUI

// R4 的色值与几何尺寸集中维护；原生控件默认装饰会改变设计稿的层次和间距。
enum ErmiTheme {
    static let ink = Color(hex: 0x183346)
    static let muted = Color(hex: 0x647c8e)
    @MainActor static var paper: Color { Color(hex: ErmiAppearance.shared.palette.surface(white: 0.92)) }
    @MainActor static var card: Color { Color(hex: ErmiAppearance.shared.palette.surface(white: 0.98)) }
    @MainActor static var line: Color { Color(hex: ErmiAppearance.shared.palette.surface(white: 0.75)) }
    @MainActor static var control: Color { Color(hex: ErmiAppearance.shared.palette.surface(white: 0.86)) }
    @MainActor static var ice: Color { Color(hex: ErmiAppearance.shared.palette.header).opacity(0.78) }
    @MainActor static var header: Color { Color(hex: ErmiAppearance.shared.palette.header) }
    @MainActor static var background: Color { Color(hex: ErmiAppearance.shared.palette.background) }
    @MainActor static var link: Color { Color(hex: ErmiAppearance.shared.palette.readableAccent) }
    @MainActor static var selected: Color { link }
    static let green = Color(hex: 0x62b49a)
    // 详情页采用灰白列表层级；仅底色轻量染色，保持各主题下文字、分隔线对比稳定。
    @MainActor private static func detailSurface(_ neutral: UInt32) -> Color {
        let base = ErmiAppearance.shared.palette.background
        let rgb = [16, 8, 0].map { shift in
            UInt32((Double((neutral >> shift) & 255) * 0.94 + Double((base >> shift) & 255) * 0.06).rounded())
        }
        return Color(hex: (rgb[0] << 16) | (rgb[1] << 8) | rgb[2])
    }
    @MainActor static var detailBackground: Color { detailSurface(0xf4f4f6) }
    static let detailInk = Color(hex: 0x26272b)
    static let detailMuted = Color(hex: 0x787884)
    static let detailLine = Color(hex: 0xdcdce4)
    @MainActor static var detailControl: Color { detailSurface(0xf1f1f5) }
    @MainActor static var detailCard: Color { Color(hex: ErmiAppearance.shared.palette.surface(white: 0.995)) }
    static let panelWidth: CGFloat = 340
    static let panelHeight: CGFloat = 437
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}

enum ErmiResources {
    // App bundle 优先于 SwiftPM 开发路径，复制 .app 后不依赖本机 .build 目录。
    static let bundle: Bundle = {
        if let root = Bundle.main.resourceURL,
           let bundled = Bundle(url: root.appendingPathComponent("Ermi_Ermi.bundle")) { return bundled }
        return Bundle.module
    }()
    static let logo = NSImage(contentsOf: bundle.url(forResource: "LogoStudy", withExtension: "png")!)!
}

struct ErmiLogo: View {
    var size: CGFloat = 27
    var body: some View {
        GeometryReader { g in
            Image(nsImage: ErmiResources.logo).resizable()
                .frame(width: g.size.width * 2.9966, height: g.size.height * 1.584)
                .offset(x: -g.size.width * 0.3868, y: -g.size.height * 0.1393)
        }.frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .circular))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .circular).stroke(.white.opacity(0.19), lineWidth: 1))
            .accessibilityLabel(L("Ermi 抬头白鼬标识"))
    }
}

struct ErmiPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

struct ProcessStopButton: View {
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Canvas { context, size in
                var p = Path()
                p.move(to: CGPoint(x: 3, y: 3)); p.addLine(to: CGPoint(x: 9, y: 9))
                p.move(to: CGPoint(x: 9, y: 3)); p.addLine(to: CGPoint(x: 3, y: 9))
                context.stroke(p, with: .color(hovered ? Color(hex: 0xa1443e) : ErmiTheme.muted), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }.frame(width: 12, height: 12).frame(width: 23, height: 23)
                .background(hovered ? Color(hex: 0xf9e7e5) : ErmiTheme.control, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hovered ? Color(hex: 0xe7c5c0) : ErmiTheme.line, lineWidth: 1))
        }.buttonStyle(ErmiPressStyle()).onHover { hovered = $0 }
    }
}

struct ErmiSortControl: View {
    @Binding var memory: Bool
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: compact ? 3 : 0) {
            sortButton(compact ? "内存" : "CPU", on: compact ? memory : !memory, value: compact)
            sortButton(compact ? "CPU" : "内存", on: compact ? !memory : memory, value: !compact)
        }.padding(compact ? 2 : 0)
            .background(compact ? ErmiTheme.control : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    private func sortButton(_ label: String, on: Bool, value: Bool) -> some View {
        Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { memory = value } } label: {
            Text(L(label)).font(.system(size: compact ? 9 : 10)).foregroundStyle(on ? (compact ? ErmiTheme.ink : .white) : ErmiTheme.muted)
                .padding(.horizontal, compact ? 7 : 8).frame(height: compact ? 19 : 24)
                .background(on ? (compact ? ErmiTheme.card : ErmiTheme.selected) : .clear, in: RoundedRectangle(cornerRadius: compact ? 4 : 7))
        }.buttonStyle(ErmiPressStyle()).accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

struct R4LineChart: View {
    let values: [Double]
    var secondary: [Double] = []
    var filled = false
    var chartLabel = "CPU 和 GPU 负载趋势"
    var body: some View {
        Canvas { context, size in
            for y in (filled ? [14.0 / 43, 35.0 / 43] : [15.0 / 74, 40.0 / 74, 65.0 / 74]) {
                var line = Path(); line.move(to: CGPoint(x: 0, y: size.height * y)); line.addLine(to: CGPoint(x: size.width, y: size.height * y))
                context.stroke(line, with: .color(ErmiTheme.line), lineWidth: 1)
            }
            draw(values, color: ErmiTheme.link, width: filled ? 1.8 : 2, filled: filled, context: &context, size: size)
            draw(secondary, color: ErmiTheme.link.opacity(0.45), width: 1.5, filled: false, context: &context, size: size)
        }.accessibilityLabel(L(filled ? "内存占用趋势" : chartLabel))
    }
    private func draw(_ data: [Double], color: Color, width: CGFloat, filled: Bool, context: inout GraphicsContext, size: CGSize) {
        guard !data.isEmpty else { return }
        // 首次有效采样只有一个点，显示当前值而不是空图，也不伪造历史曲线。
        if data.count == 1 {
            let y = size.height * (1 - min(100, max(0, data[0])) / 100)
            context.fill(Path(ellipseIn: CGRect(x: max(0, size.width - 4), y: min(max(0, y - 2), max(0, size.height - 4)), width: 4, height: 4)), with: .color(color))
            return
        }
        var line = Path()
        for (i, value) in data.enumerated() {
            let point = CGPoint(x: data.count > 1 ? size.width * Double(i) / Double(data.count - 1) : 0, y: size.height * (1 - min(100, max(0, value)) / 100))
            if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        if filled {
            var area = line; area.addLine(to: CGPoint(x: size.width, y: size.height)); area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.25), color.opacity(0)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        context.stroke(line, with: .color(color), lineWidth: width)
    }
}

// 自绘触发器避免 macOS Menu 自动在标签前加箭头、改字色；选择面板仍保留键盘焦点。
struct R4ChoiceMenu: View {
    @Binding var selection: String
    var options: [String]
    var bordered = true
    @State private var showing = false
    @State private var hovered = false
    var body: some View {
        Button { showing.toggle() } label: {
            // 已确认设计要求箭头与边框保持 13pt 留白，文字与箭头独立排版，避免原生装饰挤压标签。
            HStack(spacing: bordered ? 16 : 24) {
                // 仅翻译预定义选项；自定义方案名称按用户输入原样显示。
                Text(options.contains(selection) ? L(selection) : selection).font(.system(size: 11, weight: bordered ? .regular : .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(ErmiTheme.link)
            }.foregroundStyle(ErmiTheme.link)
                .padding(.horizontal, bordered ? 13 : 3).frame(height: bordered ? 34 : nil)
                .background(bordered ? (hovered ? ErmiTheme.control : ErmiTheme.card) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay { if bordered { RoundedRectangle(cornerRadius: 8).strokeBorder(showing || hovered ? ErmiTheme.link.opacity(0.5) : ErmiTheme.line, lineWidth: 1) } }
        }.buttonStyle(ErmiPressStyle()).fixedSize()
            .onHover { hovered = $0 }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options, id: \.self) { option in
                        Button { selection = option; showing = false } label: {
                            HStack { Text(L(option)); Spacer(); if option == selection { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) } }
                                .font(.system(size: 11)).foregroundStyle(ErmiTheme.ink).padding(.horizontal, 9).padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(ErmiPressStyle())
                    }
                }.padding(5).frame(minWidth: 160).background(ErmiTheme.card).tint(ErmiTheme.link)
            }.accessibilityLabel(L("当前选择：\(options.contains(selection) ? L(selection) : selection)"))
    }
}

// 与既有 R4ChoiceMenu 一样使用弹出列表，避免 macOS Menu 重排标签导致箭头和文字错位。
struct DetailMenu<Selection: Hashable>: View {
    var title: String
    @Binding var selection: Selection
    var options: [(Selection, String)]
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Text(L(options.first { $0.0 == selection }?.1 ?? title)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 6, weight: .semibold))
            }.font(.system(size: 9)).foregroundStyle(ErmiTheme.detailInk)
                .padding(.horizontal, 8).frame(height: 24)
                .background(ErmiTheme.detailControl, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L(title))
            .accessibilityValue(L(options.first { $0.0 == selection }?.1 ?? title))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options.indices, id: \.self) { index in
                        Button {
                            selection = options[index].0
                            showing = false
                        } label: {
                            HStack(spacing: 12) {
                                Text(L(options[index].1))
                                Spacer()
                                if selection == options[index].0 { Image(systemName: "checkmark") }
                            }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(5).frame(minWidth: 160).foregroundStyle(ErmiTheme.detailInk)
                    .background(ErmiTheme.detailCard)
                    .onExitCommand { showing = false }
            }
    }
}

struct ErmiDetailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 9))
            .foregroundStyle(ErmiTheme.link)
            .padding(.horizontal, 9).frame(minHeight: 24)
            .background(ErmiTheme.detailControl, in: RoundedRectangle(cornerRadius: 5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 页面分段选择统一复用风扇控件的底槽、等宽滑块及主题；绑定仍由各业务入口处理。
struct ErmiSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var minimumSegmentWidth: CGFloat = 92
    var fontSize: CGFloat = 10
    var segmentHeight: CGFloat = 27
    var title: (Value) -> String
    @AppStorage("ermi.reduceMotion") private var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        // 按最长翻译和最粗字重统一分配宽度，避免选中项变化时抖动或截断英文。
        let longest = options.map { (L(title($0)) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]).width }.max() ?? 0
        let width = max(minimumSegmentWidth, longest + 24)
        let index = options.firstIndex(of: selection) ?? 0
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(L(title(option))).font(.system(size: fontSize, weight: selection == option ? .semibold : .regular))
                        .foregroundStyle(selection == option ? .white : ErmiTheme.muted)
                        .lineLimit(1).frame(width: width, height: segmentHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option ? [.isSelected] : [])
            }
        }.padding(3)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(ErmiTheme.selected)
                    .shadow(color: ErmiTheme.ink.opacity(0.15), radius: 2.5, y: 2.5)
                    .frame(width: width, height: segmentHeight)
                    .offset(x: 3 + CGFloat(index) * width)
            }
            .background(ErmiTheme.control, in: RoundedRectangle(cornerRadius: 8))
            .animation(reduceMotion || systemReduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
    }
}
