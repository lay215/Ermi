import Foundation
import Observation

/// 菜单栏间距属于当前用户的全局偏好，与图标收纳权限及风扇 Helper 无关。
/// currentHost 对应 defaults -currentHost -globalDomain；缺省时读取 anyHost。
struct MenuBarSpacingStore {
    var domain: CFString = kCFPreferencesAnyApplication
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"

    func read(_ key: String) -> Int? {
        for host in [kCFPreferencesCurrentHost, kCFPreferencesAnyHost] {
            if let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, host) as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }

    func save(spacing: Int, padding: Int) -> Bool {
        guard (0...30).contains(spacing), (0...20).contains(padding) else { return false }
        CFPreferencesSetValue(Self.spacingKey as CFString, spacing as CFNumber, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSetValue(Self.paddingKey as CFString, padding as CFNumber, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            && read(Self.spacingKey) == spacing && read(Self.paddingKey) == padding
    }

    func reset() -> Bool {
        // 删除这两个键而非写死“默认数字”，让不同 macOS 版本自己选择默认值。
        // 同时清除 anyHost 的同名覆盖，避免删除本机值后又继承其他工具写入的旧设置。
        var succeeded = true
        for host in [kCFPreferencesCurrentHost, kCFPreferencesAnyHost] {
            for key in [Self.spacingKey, Self.paddingKey] {
                CFPreferencesSetValue(key as CFString, nil, domain, kCFPreferencesCurrentUser, host)
            }
            let synced = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, host)
            succeeded = succeeded && synced
        }
        return succeeded && read(Self.spacingKey) == nil && read(Self.paddingKey) == nil
    }
}

@MainActor @Observable
final class MenuBarSpacing {
    // 没有覆盖值时，6 只是自定义滑块的起始建议，不代表系统默认值。
    var spacing = 6.0
    var padding = 6.0
    private(set) var savedSpacing: Int?
    private(set) var savedPadding: Int?
    private(set) var message = ""
    private let store: MenuBarSpacingStore

    init(store: MenuBarSpacingStore = MenuBarSpacingStore()) {
        self.store = store
        reload()
    }

    var savedDescription: String {
        "已保存：间距 \(savedSpacing.map { String($0) } ?? L("系统默认")) · 内边距 \(savedPadding.map { String($0) } ?? L("系统默认"))"
    }

    func reload() {
        savedSpacing = store.read(MenuBarSpacingStore.spacingKey)
        savedPadding = store.read(MenuBarSpacingStore.paddingKey)
        spacing = Double(min(30, max(0, savedSpacing ?? 6)))
        padding = Double(min(20, max(0, savedPadding ?? 6)))
    }

    @discardableResult
    func save() -> Bool {
        // 拖动仅更新预览；明确保存才修改系统偏好，避免每帧写磁盘或打断交互。
        guard store.save(spacing: Int(spacing.rounded()), padding: Int(padding.rounded())) else {
            message = "保存失败，请重试。"; return false
        }
        reload()
        message = "已保存，注销重新登录或重启 Mac 后生效。"
        return true
    }

    func reset() {
        guard store.reset() else { message = "恢复失败，请重试。"; return }
        reload()
        message = "已恢复系统默认设置，注销重新登录或重启 Mac 后生效。"
    }
}
