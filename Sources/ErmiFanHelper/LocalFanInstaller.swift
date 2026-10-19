import Foundation
import Darwin
import ErmiCore

@MainActor enum LocalFanInstaller {
    private static let fm = FileManager.default
    private static let parent = LocalFanAuthorization.directory.deletingLastPathComponent()
    private static let domain = "system/\(LocalFanAuthorization.service)"

    static func plan(app: URL, userID: UInt32) throws -> LocalFanAuthorization {
        let client = try FanCodeSignature.fingerprint(at: app)
        let helper = try FanCodeSignature.fingerprint(at: app.appendingPathComponent("Contents/MacOS/ErmiFanHelper"))
        return try authorization(client: client, helper: helper, userID: userID)
    }

    static func authorization(client: FanCodeSignature.Fingerprint, helper: FanCodeSignature.Fingerprint, userID: UInt32) throws -> LocalFanAuthorization {
        guard client.identifier == "app.ermi.local", helper.identifier == FanServiceIdentity.service else {
            throw LocalFanError("安装源不是有效的 Ermi App 与风扇服务。")
        }
        // 两端必须由同一本机证书签名；无证书的 ad-hoc 构建不能生成长期身份授权。
        guard let certificate = client.certificateSHA1, certificate == helper.certificateSHA1 else {
            throw LocalFanError("App 与风扇服务必须使用同一本机专用证书签名。")
        }
        return try .init(userID: userID, clientHash: client.hash, helperHash: helper.hash, clientCertificateSHA1: certificate)
    }

    static func install(app: URL, clientHash: String, helperHash: String, userID: UInt32? = nil) throws {
        try requireRoot()
        // 原生管理员弹窗没有 SUDO_UID；只在 root 安装入口接受显式授权用户，保留 sudo 入口兼容。
        guard let user = userID ?? ProcessInfo.processInfo.environment["SUDO_UID"].flatMap(UInt32.init),
              user > 0, user != UInt32.max, getpwuid(user) != nil else {
            throw LocalFanError("请从你的用户会话通过 sudo 安装，不能使用不明用户身份。")
        }
        let expected = try LocalFanAuthorization(userID: user, clientHash: clientHash, helperHash: helperHash)
        guard FanCodeSignature.currentMatches(expected.helperRequirement) else { throw LocalFanError("安装器已变化，请重新打开安装入口。") }
        let lock = try installationLock()
        defer { flock(lock, LOCK_UN); close(lock) }
        guard !loaded(FanServiceIdentity.service) else { throw LocalFanError("正式版风扇服务正在运行，请先停用正式版服务。") }
        try LocalFanAuthorization.validateProtectedDirectory(LocalFanAuthorization.plist.deletingLastPathComponent())
        if LocalFanAuthorization.exists {
            _ = try LocalFanAuthorization.load()
        } else if fm.fileExists(atPath: LocalFanAuthorization.plist.path) {
            throw LocalFanError("检测到不完整的旧安装，请先使用卸载入口清理。")
        }

        let staging = parent.appendingPathComponent(".ermi-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        // 先复制到 root 独占暂存区，再验签与固定授权指纹，避免密码输入期间源文件被替换。
        let snapshot = staging.appendingPathComponent("Ermi.app")
        try fm.copyItem(at: app, to: snapshot)
        let authorization = try plan(app: snapshot, userID: user)
        // 长期授权使用证书，但这次提权确认仍必须精确对应用户确认过的两个二进制。
        guard authorization.clientHash == expected.clientHash, authorization.helperHash == expected.helperHash else {
            throw LocalFanError("授权期间构建已改变，请重新运行安装器。")
        }
        let incoming = staging.appendingPathComponent("service")
        try fm.createDirectory(at: incoming, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let helper = incoming.appendingPathComponent("ErmiFanHelper")
        let source = snapshot.appendingPathComponent("Contents/MacOS/ErmiFanHelper")
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LocalFanError("控制服务必须为普通可执行文件。") }
        try fm.copyItem(at: source, to: helper)
        // 复制可能携带 ACL；先清除额外写权限，再设置 root 所有权。
        let acl = Process()
        acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["-N", helper.path]
        try acl.run(); acl.waitUntilExit()
        guard acl.terminationStatus == 0 else { throw LocalFanError("无法清除控制服务的额外文件权限。") }
        try fm.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: helper.path)
        try JSONEncoder().encode(authorization).write(to: incoming.appendingPathComponent("authorization.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: incoming.appendingPathComponent("authorization.json").path)
        guard FanCodeSignature.matches(at: helper, requirement: expected.helperRequirement) else { throw LocalFanError("暂存控制服务校验失败。") }

        let oldPlist = fm.fileExists(atPath: LocalFanAuthorization.plist.path) ? try Data(contentsOf: LocalFanAuthorization.plist) : nil
        let wasLoaded = loaded(LocalFanAuthorization.service)
        if wasLoaded { try command(["bootout", domain]) }
        do { try verifyRecovered() }
        catch {
            if wasLoaded { try? command(["bootstrap", "system", LocalFanAuthorization.plist.path]) }
            throw error
        }
        let backup = parent.appendingPathComponent(".ermi-previous-\(UUID().uuidString)")
        var backedUp = false
        var installed = false
        do {
            if LocalFanAuthorization.exists { try fm.moveItem(at: LocalFanAuthorization.directory, to: backup); backedUp = true }
            try fm.moveItem(at: incoming, to: LocalFanAuthorization.directory)
            installed = true
            let plist: [String: Any] = [
                "Label": LocalFanAuthorization.service,
                "ProgramArguments": [LocalFanAuthorization.executable.path, "--local-development"],
                "MachServices": [LocalFanAuthorization.service: true],
                "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
                "ExitTimeOut": 30, "ProcessType": "Background"
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: LocalFanAuthorization.plist, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: LocalFanAuthorization.plist.path)
            try command(["bootstrap", "system", LocalFanAuthorization.plist.path])
        } catch {
            // 安装失败时恢复原来的磁盘版本与注册状态，不留下新版文件配旧授权的半安装。
            if installed { try? command(["bootout", domain]); try? fm.removeItem(at: LocalFanAuthorization.directory) }
            if backedUp { try? fm.moveItem(at: backup, to: LocalFanAuthorization.directory) }
            if let oldPlist { try? oldPlist.write(to: LocalFanAuthorization.plist, options: .atomic) }
            else { try? fm.removeItem(at: LocalFanAuthorization.plist) }
            if wasLoaded { try? command(["bootstrap", "system", LocalFanAuthorization.plist.path]) }
            throw error
        }
        if backedUp { try? fm.removeItem(at: backup) }
        print("本机控制服务已安装。返回 Ermi 点击“连接本机服务”；安装未应用任何预设。")
    }

    static func uninstall() throws {
        try requireRoot()
        let lock = try installationLock()
        defer { flock(lock, LOCK_UN); close(lock) }
        // 残缺授权也必须能卸载；只检查固定路径归属，不依赖 JSON 可解码。
        try LocalFanAuthorization.validateProtectedDirectory(LocalFanAuthorization.plist.deletingLastPathComponent())
        if LocalFanAuthorization.exists { try LocalFanAuthorization.validateProtectedDirectory(LocalFanAuthorization.directory) }
        var plistInfo = stat()
        if lstat(LocalFanAuthorization.plist.path, &plistInfo) == 0 {
            guard plistInfo.st_uid == 0, plistInfo.st_mode & S_IFMT == S_IFREG, plistInfo.st_mode & 0o022 == 0 else {
                throw LocalFanError("旧服务配置的文件归属或权限异常。")
            }
        } else if errno != ENOENT { throw LocalFanError("无法检查旧服务配置。") }
        let wasLoaded = loaded(LocalFanAuthorization.service)
        if wasLoaded { try command(["bootout", domain]) }
        do { try verifyRecovered() }
        catch {
            if wasLoaded { try? command(["bootstrap", "system", LocalFanAuthorization.plist.path]) }
            throw error
        }
        // 只删除本机模式固定文件，保留用户预设与硬件恢复日志，正式版服务不受影响。
        if fm.fileExists(atPath: LocalFanAuthorization.plist.path) { try fm.removeItem(at: LocalFanAuthorization.plist) }
        if LocalFanAuthorization.exists { try fm.removeItem(at: LocalFanAuthorization.directory) }
        print("本机控制服务已卸载，风扇预设保留。")
    }

    private static func verifyRecovered() throws {
        // 不能只凭进程已退出就认定安全；日志仍有接管记录时拒绝替换或删除恢复程序。
        struct Journal: Decodable { let indices: [Int]; let unlock: Bool }
        let file = URL(fileURLWithPath: "/private/var/db/app.ermi.fan-helper/ownership.json")
        var info = stat()
        if lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw LocalFanError("无法确认风扇恢复日志。") }
            return
        }
        guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else { throw LocalFanError("风扇恢复日志权限无效。") }
        try LocalFanAuthorization.validateProtectedDirectory(file.deletingLastPathComponent())
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
        guard journal.indices.isEmpty, !journal.unlock else { throw LocalFanError("风扇尚未恢复系统控制，已保留原服务。请先在 Ermi 中恢复系统自动后再安装或卸载。") }
    }
    private static func requireRoot() throws {
        guard geteuid() == 0 else { throw LocalFanError("需要管理员授权，请使用本机安装入口或 sudo。") }
    }
    private static func installationLock() throws -> Int32 {
        try LocalFanAuthorization.validateProtectedDirectory(parent)
        let path = parent.appendingPathComponent(".app.ermi.fan-helper.local.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalFanError("无法创建安装锁。") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw LocalFanError("已有安装任务运行，或安装锁权限无效。")
        }
        return fd
    }
    private static func loaded(_ label: String) -> Bool { (try? run(["print", "system/\(label)"]).0) == 0 }
    private static func command(_ args: [String]) throws {
        let result = try run(args)
        guard result.0 == 0 else { throw LocalFanError("launchctl \(args.first ?? "") 失败：\(result.1)") }
    }
    private static func run(_ args: [String]) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        let error = Pipe(); task.standardError = error
        try task.run()
        let data = error.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
