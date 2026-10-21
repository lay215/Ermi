import Foundation
import Security

/// XPC只传递有限的领域命令，不暴露SMC键、文件路径或任意shell命令。
@objc public protocol FanServiceProtocol {
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
}
public enum FanServiceCommand: Codable, Sendable {
    case inspect, heartbeat, restore
    case apply(FanPreset)
}
public struct FanServiceReply: Codable, Sendable {
    public var capabilities: [FanCapability]
    // inspect 的空结果与 heartbeat 未携带能力是不同状态；可选字段兼容旧 helper 回包。
    public var capabilityProbeCompleted: Bool?
    // 旧 helper 缺少此字段；新 App 必须明确获知支持后才提交具体传感器温控。
    public var supportsTemperatureSensorSelection: Bool?
    public var status: FanControlStatus
    public var error: String?
    public init(capabilities: [FanCapability] = [], status: FanControlStatus = .init(phase: .system), error: String? = nil, capabilityProbeCompleted: Bool? = nil, supportsTemperatureSensorSelection: Bool? = nil) {
        self.capabilities = capabilities; self.status = status; self.error = error
        self.capabilityProbeCompleted = capabilityProbeCompleted
        self.supportsTemperatureSensorSelection = supportsTemperatureSensorSelection
    }
}
public enum FanServiceIdentity {
    public static let service = "app.ermi.fan-helper"
    public static let daemonPlist = "app.ermi.fan-helper.plist"
    // 正式分发两端由同一开发者签名；本机模式另走 root 持有的精确构建授权，不在此回退。
    public static func requirement(identifier: String) -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
