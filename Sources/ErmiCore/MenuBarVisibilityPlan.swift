import Foundation

/// 只隐藏用户明确选择、当前可读且仍在运行的 App，防止旧配置误伤未知入口。
public struct MenuBarVisibilityPlan: Equatable, Sendable {
    public static let systemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]
    public let hidden: Set<String>
    public let allowed: Set<String>

    public init(selected: Set<String>, discovered: Set<String>, running: Set<String>, own: String) {
        // 自身和系统入口始终可见，即使配置被手工改写也不隐藏它们。
        let protected = Self.systemOwners.union([own])
        hidden = selected.intersection(discovered).intersection(running).subtracting(protected)
        allowed = running.subtracting(hidden).union(protected)
    }
}
