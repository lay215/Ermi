import Foundation
import Security
import CryptoKit
import Darwin

public struct LocalFanAuthorization: Codable, Equatable, Sendable {
    public static let service = "app.ermi.fan-helper.local"
    public static let directory = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/app.ermi.fan-helper.local")
    public static let file = directory.appendingPathComponent("authorization.json")
    public static let executable = directory.appendingPathComponent("ErmiFanHelper")
    public static let plist = URL(fileURLWithPath: "/Library/LaunchDaemons/app.ermi.fan-helper.local.plist")
    public let version: Int
    public let userID: UInt32
    public let clientHash: String
    public let helperHash: String
    public let clientCertificateSHA1: String?

    public init(userID: UInt32, clientHash: String, helperHash: String) throws {
        version = 1; clientCertificateSHA1 = nil; self.userID = userID; self.clientHash = clientHash; self.helperHash = helperHash
        try validate()
    }
    public init(userID: UInt32, clientHash: String, helperHash: String, clientCertificateSHA1: String) throws {
        version = 2; self.userID = userID; self.clientHash = clientHash; self.helperHash = helperHash
        self.clientCertificateSHA1 = clientCertificateSHA1
        try validate()
    }
    public func validate() throws {
        // 哈希只能是系统返回的 20 字节 cdhash，不能让配置注入任意签名表达式。
        // v1 只读取兼容；v2 绑定本机证书身份，clientHash 留作安装审计而不限制后续界面构建。
        guard (version == 1 && clientCertificateSHA1 == nil) ||
                (version == 2 && clientCertificateSHA1.map(Self.validHash) == true) else {
            throw LocalFanError("本机授权格式或证书无效，请重新安装。")
        }
        guard userID > 0, userID != UInt32.max,
              Self.validHash(clientHash), Self.validHash(helperHash) else { throw LocalFanError("本机授权文件无效，请重新安装。") }
    }
    private static func validHash(_ hash: String) -> Bool {
        hash.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public var clientRequirement: String {
        if version == 2, let clientCertificateSHA1 {
            return "identifier \"app.ermi.local\" and certificate leaf = H\"\(clientCertificateSHA1)\""
        }
        return "identifier \"app.ermi.local\" and cdhash H\"\(clientHash)\""
    }
    public var helperRequirement: String { "identifier \"app.ermi.fan-helper\" and cdhash H\"\(helperHash)\"" }

    public static var exists: Bool {
        var info = stat()
        // 连符号链接和损坏安装也视为“已安装”，不能悄悄退回另一种控制服务。
        return lstat(directory.path, &info) == 0
    }
    public static func load() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: readProtectedFile(file))
        try value.validate()
        return value
    }
    public func validateClient() throws {
        try validate()
        guard getuid() == userID, FanCodeSignature.currentMatches(clientRequirement) else {
            throw LocalFanError("当前 Ermi 与本机授权不匹配。签名身份或用户发生变化后，请更新本机授权并重启 Ermi。")
        }
    }
    public func validateHelper() throws {
        try validate()
        guard geteuid() == 0, FanCodeSignature.currentMatches(helperRequirement) else {
            throw LocalFanError("控制服务与本机授权不匹配，拒绝启动。")
        }
    }

    // 授权只能由 root 持有；逐级拒绝可写目录、符号链接，读取时以 fd 复核文件身份。
    // owner 参数仅供模块内测试使用；生产入口固定使用 root。
    static func readProtectedFile(_ url: URL, owner: uid_t = 0) throws -> Data {
        try validateProtectedDirectory(url.deletingLastPathComponent(), owner: owner)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalFanError("不能读取本机授权，请先安装本机控制服务。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, info.st_nlink == 1, info.st_size > 0, info.st_size <= 8192 else {
            throw LocalFanError("本机授权文件的权限或大小不安全。")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw LocalFanError("本机授权文件未完整读取。") }
        return Data(bytes)
    }
    public static func validateProtectedDirectory(_ url: URL) throws {
        try validateProtectedDirectory(url, owner: 0)
    }
    static func validateProtectedDirectory(_ url: URL, owner: uid_t) throws {
        var current = url
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0, (info.st_uid == 0 || info.st_uid == owner),
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
                throw LocalFanError("授权目录必须由管理员保护，且不能是符号链接：\(current.path)")
            }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }
}

public struct LocalFanError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum FanCodeSignature {
    public struct Fingerprint: Sendable {
        public let identifier: String
        public let hash: String
        public let certificateSHA1: String?
        public init(identifier: String, hash: String, certificateSHA1: String?) {
            self.identifier = identifier; self.hash = hash; self.certificateSHA1 = certificateSHA1
        }
    }
    public static func fingerprint(at url: URL) throws -> Fingerprint {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw LocalFanError("代码签名校验失败：\(url.lastPathComponent)")
        }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data, hash.count == 20,
              let identifier = info[kSecCodeInfoIdentifier as String] as? String else { throw LocalFanError("无法读取代码签名指纹。") }
        // Security requirement 的 certificate leaf 使用证书 DER 的 SHA-1 指纹，不是 CodeDirectory 哈希。
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let certificateHash = certificates?.first.map {
            Insecure.SHA1.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02x", $0) }.joined()
        }
        return Fingerprint(identifier: identifier, hash: hash.map { String(format: "%02x", $0) }.joined(), certificateSHA1: certificateHash)
    }
    public static func requirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw LocalFanError("代码身份规则无效。")
        }
        return requirement
    }
    public static func currentMatches(_ text: String) -> Bool {
        var code: SecCode?
        guard let requirement = try? requirement(text), SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    public static func matches(at url: URL, requirement text: String) -> Bool {
        var code: SecStaticCode?
        guard let requirement = try? requirement(text), SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        // cdhash 对应当前架构的 CodeDirectory；通用二进制的其他架构拥有不同哈希。
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }
}
