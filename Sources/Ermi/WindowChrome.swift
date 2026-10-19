import AppKit
import SwiftUI

// 原生窗口按钮嵌入单行导航，保留系统关闭、最小化及缩放行为。
struct ErmiWindowTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarView { TitlebarView() }
    func updateNSView(_ nsView: TitlebarView, context: Context) {}

    final class TitlebarView: NSView {
        private(set) var buttons: [NSButton] = []
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            buttons.forEach { $0.removeFromSuperview() }
            buttons.removeAll()
            guard let window else { return }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let actions = [#selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.performZoom(_:))]
            for (index, kind) in kinds.enumerated() {
                // 标题栏持有的按钮会被 AppKit 重排；使用系统工厂生成独立原生按钮，
                // 由本视图定位，操作仍交给窗口，保留关闭/最小化/缩放及窗口代理判断。
                window.standardWindowButton(kind)?.isHidden = true
                guard let button = NSWindow.standardWindowButton(kind, for: window.styleMask) else { continue }
                button.target = window
                button.action = actions[index]
                button.autoresizingMask = []
                addSubview(button)
                buttons.append(button)
            }
            needsLayout = true
        }
        override func layout() {
            super.layout()
            for (index, button) in buttons.enumerated() {
                button.frame = NSRect(x: CGFloat(18 + index * 20), y: (bounds.height - 12) / 2, width: 12, height: 12)
            }
        }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    }
}

struct ErmiWindowContent: View {
    @Bindable var model: MonitorModel
    var previewOrganizer: MenuBarOrganizer? = nil
    var body: some View {
        ErmiDetailView(model: model, integratedChrome: true, previewOrganizer: previewOrganizer)
            .background(ErmiTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .circular))
            .ignoresSafeArea()
    }
}

/// 仅导航空白处接收拖动；上层按钮继续接收点击，内容区域不参与拖窗。
struct ErmiWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
