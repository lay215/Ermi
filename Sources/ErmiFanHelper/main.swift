import Foundation
import ErmiCore
import Darwin

final class Session: NSObject, FanServiceProtocol, @unchecked Sendable {
    let id = UUID()
    let life = SessionLife()
    let runtime: ServiceRuntime
    init(runtime: ServiceRuntime) { self.runtime = runtime }
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        // 拒绝畸形/过大报文，避免特权进程承接无限输入。
        let response = Reply(reply)
        Task {
            let result: FanServiceReply
            if data.count <= 65536, let command = try? JSONDecoder().decode(FanServiceCommand.self, from: data) {
                result = await runtime.execute(command, client: id, life: life)
            } else { result = .init(error: "无效控制请求") }
            response.send((try? JSONEncoder().encode(result)) ?? Data())
        }
    }
}
final class Reply: @unchecked Sendable {
    let send: (Data) -> Void
    init(_ send: @escaping (Data) -> Void) { self.send = send }
}
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let device = SMCFanDevice()
    let runtime: ServiceRuntime
    let requirement: String
    let localUserID: uid_t?
    init(requirement: String, localUserID: uid_t?) {
        self.requirement = requirement; self.localUserID = localUserID
        self.runtime = ServiceRuntime(device: device)
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // 本机授权限定为安装时的登录用户，其他账户即使拿到同一构建也不能接管。
        if let localUserID, connection.effectiveUserIdentifier != localUserID { return false }
        connection.setCodeSigningRequirement(requirement)
        let session = Session(runtime: runtime)
        connection.exportedInterface = NSXPCInterface(with: FanServiceProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [runtime] in session.life.close(); Task { await runtime.disconnected(session.id) } }
        connection.interruptionHandler = { [runtime] in session.life.close(); Task { await runtime.disconnected(session.id) } }
        connection.resume()
        return true
    }
}

// 安装入口是有限命令；管理员弹窗或 sudo 完成提权，App 不接触管理员密码。
let arguments = CommandLine.arguments
if arguments.contains("--local-plan") || arguments.contains("--install-local") || arguments.contains("--uninstall-local") {
    do {
        if arguments.count == 3, arguments[1] == "--local-plan" {
            let plan = try LocalFanInstaller.plan(app: URL(fileURLWithPath: arguments[2]), userID: getuid())
            print("\(plan.clientHash) \(plan.helperHash)")
        } else if (arguments.count == 5 || arguments.count == 6), arguments[1] == "--install-local" {
            let explicitUser: UInt32?
            if arguments.count == 6 {
                guard let value = UInt32(arguments[5]), value > 0, value != UInt32.max else {
                    throw LocalFanError("安装用户身份无效。")
                }
                explicitUser = value
            } else { explicitUser = nil }
            try LocalFanInstaller.install(app: URL(fileURLWithPath: arguments[2]), clientHash: arguments[3], helperHash: arguments[4], userID: explicitUser)
        } else if arguments.count == 2, arguments[1] == "--uninstall-local" {
            try LocalFanInstaller.uninstall()
        } else { throw LocalFanError("本机安装参数无效。") }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(78)
    }
}

// 诊断入口只读硬件能力，普通用户可执行；不会读取恢复日志或接管设备。
if CommandLine.arguments.contains("--inspect") {
    Task {
        do {
            let device = SMCFanDevice()
            let capabilities = try await device.capabilities()
            let snapshot = try await device.snapshot()
            print(String(data: try JSONEncoder().encode(capabilities), encoding: .utf8)!)
            print(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!)
            exit(0)
        } catch { print("Read-only inspection failed: \(error)"); exit(1) }
    }
    RunLoop.current.run()
}

let requirement: String
let localUserID: uid_t?
let serviceName: String
do {
    guard geteuid() == 0 else { throw LocalFanError("风扇控制服务需要 root 权限。") }
    if arguments.contains("--local-development") {
        let authorization = try LocalFanAuthorization.load()
        try authorization.validateHelper()
        requirement = authorization.clientRequirement
        localUserID = authorization.userID
        serviceName = LocalFanAuthorization.service
    } else {
        // 显式本机模式以外仍保留 Developer ID 规则；不能因缺证书而自动降低校验要求。
        guard !LocalFanAuthorization.exists, let signed = FanServiceIdentity.requirement(identifier: "app.ermi.local") else {
            throw LocalFanError("正式控制服务需要 TeamID 签名，且不能与本机模式同时运行。")
        }
        requirement = signed; localUserID = nil; serviceName = FanServiceIdentity.service
    }
} catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(78) }
let delegate = ListenerDelegate(requirement: requirement, localUserID: localUserID)
let listener = NSXPCListener(machServiceName: serviceName)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
Task {
    do { try await delegate.device.recoverPreviousSession() }
    catch { fputs("Ermi previous session recovery failed: \(error)\n", stderr); exit(75) }
    listener.resume()
}
Task {
    while !Task.isCancelled {
        await delegate.runtime.tick()
        try? await Task.sleep(for: .seconds(1))
    }
}
// launchd停止服务时先恢复；SIGKILL不能运行清理代码，另由设备接管日志恢复。
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
termination.setEventHandler {
    Task {
        let restored = await delegate.runtime.shutdown()
        exit(restored ? 0 : 75)
    }
}
termination.resume()
RunLoop.current.run()
