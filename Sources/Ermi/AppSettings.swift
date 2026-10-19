import AppKit
import SwiftUI
import ServiceManagement
@preconcurrency import ApplicationServices
import Darwin

// 将系统登录项边界注入，诊断可验证授权状态和异步失败而不改动真实登录项。
@MainActor
struct LoginItemService {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () async throws -> Void
    static var system: Self {
        Self(status: { SMAppService.mainApp.status }, register: { try SMAppService.mainApp.register() }, unregister: { try await SMAppService.mainApp.unregister() })
    }
}

@MainActor
@Observable
final class AppSettingsModel {
    private(set) var loginStatus: SMAppService.Status
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var busy = false
    var errorMessage: String?
    @ObservationIgnored private let loginService: LoginItemService

    init(loginService: LoginItemService = .system) {
        self.loginService = loginService
        loginStatus = loginService.status()
    }

    // 不保存“已开启”的副本；用户可在系统设置撤销，系统状态始终为准。
    var loginRegistered: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
    var loginDescription: String {
        switch loginStatus {
        case .enabled: "登录后自动在菜单栏启动 Ermi。"
        case .requiresApproval: "已注册，等待你在系统设置中允许；目前不会自动启动。"
        case .notRegistered: "当前未开启登录启动。"
        case .notFound: "系统尚未识别登录项。可尝试开启；若失败，请将 Ermi.app 放入应用程序目录后重试。"
        @unknown default: "无法识别系统返回的登录项状态。"
        }
    }

    func refresh() {
        loginStatus = loginService.status()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func setLoginEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        refresh()
        guard enabled != loginRegistered else { return }
        busy = true
        errorMessage = nil
        defer { busy = false; refresh() }
        do {
            if enabled {
                try loginService.register()
            } else {
                // 仅取消下次登录启动，不退出正在运行的主应用，也不影响风扇服务。
                try await loginService.unregister()
            }
        } catch {
            errorMessage = "无法更新登录启动：\(error.localizedDescription)"
        }
    }

    func openAccessibilitySettings() {
        // 与图标整理入口使用相同的系统授权 API，不请求屏幕录制或输入监听。
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"), !NSWorkspace.shared.open(url) {
            errorMessage = "无法打开系统设置，请手动前往“隐私与安全性”管理 Ermi 权限。"
        }
    }
}

struct AppSettingsView: View {
    @Bindable var model: MonitorModel
    var embedded = false
    var isActive = true
    @State private var settings = AppSettingsModel()
    @AppStorage("ermi.reduceMotion") private var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var page = Diagnostics.previewOption("--settings-page") == "permissions" ? "权限与服务" : Diagnostics.previewOption("--settings-page") == "about" ? "关于" : "通用与外观"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageSelector
                // 二级导航只切换展示分组，设置模型和持久化绑定保留原有生命周期。
                if page == "通用与外观" {
                    Text(L("按你的习惯调整 Ermi。更改即时生效并自动保存，主题同步应用到所有界面。"))
                        .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).padding(.vertical, 3)
                    SettingsSection {
                        LanguageSettings()
                        SettingsDivider()
                        AppearanceSettings()
                    }
                    SettingsSection {
                        SettingsRow("登录时启动 Ermi", description: settings.loginDescription) {
                            Toggle(L("登录时启动 Ermi"), isOn: Binding(get: { settings.loginRegistered }, set: { value in
                                Task { await settings.setLoginEnabled(value) }
                            })).labelsHidden().disabled(settings.busy)
                        }
                        if settings.loginStatus == .requiresApproval {
                            Button(L("前往登录项设置")) { SMAppService.openSystemSettingsLoginItems() }.padding(12)
                        }
                        SettingsDivider()
                        SettingsRow("菜单栏显示温度", description: "关闭后仅显示白鼬图标，不影响温度监测与风扇控制。") {
                            Toggle(L("菜单栏显示温度"), isOn: $model.showMenuBarTemperature).labelsHidden()
                        }
                        SettingsDivider()
                        SettingsRow("减少动态效果", description: systemReduceMotion ? "系统已开启减少动态效果，页面切换将遵循系统设置。" : "减少页面切换的位移动画。") {
                            Toggle(L("减少动态效果"), isOn: $reduceMotion).labelsHidden()
                        }
                    }
                } else if page == "权限与服务" {
                    Text(L("管理图标整理权限与风扇服务。系统授权仍由 macOS 确认。"))
                        .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).padding(.vertical, 3)
                    SettingsSection {
                        SettingsRow("图标整理权限", description: "通过辅助功能读取并整理菜单栏图标") {
                            Text(L(settings.accessibilityGranted ? "已授权" : "未授权")).foregroundStyle(ErmiTheme.detailMuted)
                            Button(L("管理权限…")) { settings.openAccessibilitySettings() }
                        }
                        SettingsDivider()
                        SettingsRow("登录项与后台服务", description: "查看系统允许的登录项与后台活动") {
                            Button(L("打开系统设置…")) { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    SettingsSection {
                        SettingsRow("风扇服务", description: "提供风扇调节所需的后台控制能力") {
                            Text(L(model.helperReady ? "已连接" : "未连接"))
                                .foregroundStyle(model.helperReady ? ErmiTheme.green : ErmiTheme.detailMuted)
                        }
                        if model.usesLocalFanControl {
                            SettingsDivider()
                            SettingsRow("服务管理", description: model.localFanSetupMessage) {
                                Button(L("安装 / 更新授权")) { model.openLocalFanInstaller() }
                                Button(L("卸载服务")) { model.openLocalFanInstaller(uninstall: true) }
                            }.disabled(model.controlBusy || model.installerOpening)
                        }
                        if !model.helperReady {
                            SettingsDivider()
                            SettingsRow("连接状态") {
                                Button(L(model.fanServiceActionTitle)) { Task { await model.enableFanControl() } }
                                    .disabled(model.controlBusy || model.installerOpening)
                            }
                        }
                        if model.installerOpening || model.controlNeedsAttention {
                            Text(L(model.controlNotice)).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).padding(12)
                        }
                    }
                } else {
                    Text(L("Ermi · 轻量的 Mac 状态与风扇管理工具"))
                        .font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted).padding(.vertical, 3)
                    SettingsSection {
                        SettingsRow("版本") { Text(L(Self.version)) }
                        SettingsDivider()
                        SettingsRow("系统") { Text(ProcessInfo.processInfo.operatingSystemVersionString) }
                        SettingsDivider()
                        SettingsRow("设备型号") { Text(L(Self.hardwareModel)) }
                    }
                }
                if let error = settings.errorMessage {
                    SettingsSection {
                        SettingsRow("刷新状态", description: error) {
                            Button(L("刷新状态")) { settings.refresh() }
                        }
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .buttonStyle(ErmiDetailButtonStyle())
        .font(.system(size: 9))
        .foregroundStyle(ErmiTheme.detailInk)
        .background(ErmiTheme.detailBackground)
        .frame(width: embedded ? nil : 520, height: embedded ? nil : 600)
        .tint(ErmiTheme.link)
        .environment(\.locale, AppLocalization.shared.locale)
        .navigationTitle(L("Ermi 设置"))
        .onAppear { settings.refresh() }
        // 从系统设置返回时立即重新读取；页面打开期间也同步外部授权变化。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in settings.refresh() }
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                settings.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var pageSelector: some View {
        ErmiSegmentedControl(options: ["通用与外观", "权限与服务", "关于"], selection: $page) { $0 }
    }

    private static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return version }
        return "\(version) (\(build))"
    }

    private static let hardwareModel: String = {
        // 仅展示机型，不读取序列号等设备标识。
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size < 1024 else { return "暂不可用" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "暂不可用" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}

// 列表分组统一使用外边框，只有完整设置行之间才画分隔线，说明文字不独占一行边界。
struct SettingsSection<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ErmiTheme.detailCard, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(ErmiTheme.detailLine, lineWidth: 0.5))
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(ErmiTheme.detailLine).frame(height: 0.5) }
}

struct SettingsRow<Controls: View>: View {
    var title: String
    var description: String?
    var indented: Bool
    @ViewBuilder var controls: () -> Controls
    init(_ title: String, description: String? = nil, indented: Bool = false, @ViewBuilder controls: @escaping () -> Controls) {
        self.title = title
        self.description = description
        self.indented = indented
        self.controls = controls
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L(title)).font(.system(size: 10, weight: .medium)).foregroundStyle(ErmiTheme.detailInk)
                if let description {
                    Text(L(description)).font(.system(size: 8)).foregroundStyle(ErmiTheme.detailMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.leading, indented ? 12 : 0).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6, content: controls).font(.system(size: 9)).fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: 46)
    }
}
