import SwiftUI

private struct ProcessConfirmationModifier: ViewModifier {
    @Binding var pending: DisplayProcess?
    @Bindable var model: MonitorModel
    @FocusState private var cancelFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.blur(radius: pending == nil ? 0 : 3).allowsHitTesting(pending == nil).disabled(pending != nil).accessibilityHidden(pending != nil)
            .overlay {
                if let process = pending {
                    ZStack {
                        ErmiTheme.ink.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 0) {
                            ProcessAppIcon(process: process, size: 32)
                                .frame(width: 40, height: 40).background(ErmiTheme.control, in: RoundedRectangle(cornerRadius: 11)).padding(.bottom, 13)
                            Text(L("结束 \(process.name)？")).font(.system(size: 16, weight: .semibold)).foregroundStyle(ErmiTheme.ink).multilineTextAlignment(.center).lineLimit(3)
                            Text(L("退出会请求 App 正常结束；强制退出可能丢失未保存的内容。"))
                                .font(.system(size: 11)).foregroundStyle(ErmiTheme.muted).multilineTextAlignment(.center).lineSpacing(5).padding(.vertical, 10)
                            Text(L(model.designPreview ? "交互演示 · 不会结束本机进程" : "执行前将再次核实进程身份"))
                                .font(.system(size: 9)).foregroundStyle(ErmiTheme.muted).padding(.top, 8).padding(.bottom, 18)
                            HStack(spacing: 7) {
                                dialogButton("取消", color: ErmiTheme.link, background: ErmiTheme.control) { pending = nil }
                                    .focused($cancelFocused).keyboardShortcut(.cancelAction)
                                dialogButton("强制退出", color: Color(hex: 0xa04842), background: Color(hex: 0xf4e8e6)) { finish(process, force: true) }
                                dialogButton("退出", color: .white, background: ErmiTheme.selected) { finish(process, force: false) }
                            }
                        }.padding(.top, 24).padding(.horizontal, 20).padding(.bottom, 18).frame(width: 300)
                            .background(ErmiTheme.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ErmiTheme.line, lineWidth: 1))
                            .shadow(color: ErmiTheme.ink.opacity(0.3), radius: 40, y: 24)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                            .task { cancelFocused = true }.onExitCommand { pending = nil }
                    }.accessibilityAddTraits(.isModal)
                }
            }.animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: pending?.id)
    }
    private func dialogButton(_ title: String, color: Color, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(L(title)).font(.system(size: 11)).foregroundStyle(color).frame(maxWidth: .infinity).frame(height: 33).background(background, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(ErmiPressStyle())
    }
    private func finish(_ process: DisplayProcess, force: Bool) {
        pending = nil
        // 截图诊断行没有真实进程身份，绝不沿用显示名称去寻找并结束本机 App。
        guard let source = process.source, !model.designPreview else { model.feedback = "设计预览不会结束本机进程。"; return }
        Task { await model.end(source, force: force) }
    }
}

extension View {
    func ermiProcessConfirmation(pending: Binding<DisplayProcess?>, model: MonitorModel) -> some View { modifier(ProcessConfirmationModifier(pending: pending, model: model)) }
}
