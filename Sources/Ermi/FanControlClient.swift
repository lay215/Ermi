import Foundation
import ServiceManagement
import ErmiCore
import OSLog

// 仅记录阶段耗时和命令类型，不写入授权文件、签名规则或用户预设内容。
struct FanRequestTiming {
    let command: String
    let authorizationMS: Double
    let connectionSetupMS: Double
    let replyMS: Double
    let totalMS: Double
    let succeeded: Bool
    var summary: String {
        String(format: "command=%@ authorization_ms=%.2f connection_setup_ms=%.2f reply_ms=%.2f total_ms=%.2f succeeded=%@",
               command, authorizationMS, connectionSetupMS, replyMS, totalMS, succeeded ? "true" : "false")
    }
    func log() {
        let logger = Logger(subsystem: "app.ermi.local", category: "FanConnection")
        // 慢请求与失败保留在常规日志；快速心跳仅在诊断日志中记录，避免持续刷屏。
        if !succeeded || totalMS >= 1000 { logger.notice("\(summary, privacy: .public)") }
        else { logger.debug("\(summary, privacy: .public)") }
    }
}

private final class PendingFanReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FanServiceReply, Error>?
    init(_ continuation: CheckedContinuation<FanServiceReply, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<FanServiceReply, Error>) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}
private struct FanClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// 界面只读取最近校验快照；连接时仍逐次校验，快照本身不能授予控制权限。
struct FanClientAvailability: Sendable {
    var usesLocalMode: Bool
    var message: String
    var serviceName: String?
    var requirement: String?
    var ready: Bool { serviceName != nil && requirement != nil }
}

@MainActor final class FanControlClient {
    private var connection: NSXPCConnection?
    private var generation = UUID()
    // 与 XPC 连接代次分离：正常建连不作废并行只读校验，显式断连/睡眠才作废。
    private var authorizationEpoch = UUID()
    private var connectionIdentity: String?
    private let checkAuthorization: @Sendable () -> FanClientAvailability
    private let onTiming: @MainActor (FanRequestTiming) -> Void
    private var availability = FanClientAvailability(usesLocalMode: true, message: "正在检查控制授权…")
    var usesLocalMode: Bool { availability.usesLocalMode }
    var localSetupMessage: String { availability.message }
    var ready: Bool { availability.ready }

    init(checkAuthorization: @escaping @Sendable () -> FanClientAvailability = FanControlClient.inspectAuthorization,
         onTiming: @escaping @MainActor (FanRequestTiming) -> Void = { $0.log() }) {
        self.checkAuthorization = checkAuthorization
        self.onTiming = onTiming
    }

    nonisolated private static func inspectAuthorization() -> FanClientAvailability {
        let local = LocalFanAuthorization.exists || FanServiceIdentity.requirement(identifier: FanServiceIdentity.service) == nil
        if local {
            guard LocalFanAuthorization.exists else {
                return .init(usesLocalMode: true, message: "点击安装后在 macOS 弹窗中验证。固定签名身份可沿用授权；安装不会应用预设。")
            }
            do {
                let authorization = try LocalFanAuthorization.load()
                try authorization.validateClient()
                guard FanCodeSignature.matches(at: LocalFanAuthorization.executable, requirement: authorization.helperRequirement) else {
                    throw FanClientError(message: "已安装的本机服务与授权不匹配，请更新本机授权。")
                }
                return .init(usesLocalMode: true, message: authorization.version == 2
                             ? "本机签名授权有效；同一签名的界面更新无需重新授权。更新风扇服务时请点击安装 / 更新授权。"
                             : "当前为旧构建授权；更新一次后可迁移到固定签名身份。",
                             serviceName: LocalFanAuthorization.service, requirement: authorization.helperRequirement)
            } catch { return .init(usesLocalMode: true, message: error.localizedDescription) }
        }
        let requirement = FanServiceIdentity.requirement(identifier: FanServiceIdentity.service)
        let enabled = SMAppService.daemon(plistName: FanServiceIdentity.daemonPlist).status == .enabled
        return .init(usesLocalMode: false, message: enabled ? "控制服务已启用。" : "请先在风扇预设中启用控制服务。",
                     serviceName: enabled ? FanServiceIdentity.service : nil, requirement: enabled ? requirement : nil)
    }

    private func checkedAvailability() async throws -> FanClientAvailability {
        let epoch = authorizationEpoch
        let check = checkAuthorization
        // Security 的完整签名验证会同步读取二进制；放到后台队列，避免阻塞 Tab 点击和动画。
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: check()) }
        }
        // 后台校验不可取消其系统调用，但旧结果不得在退出、睡眠或断连后重新建立连接。
        try Task.checkCancellation()
        guard epoch == authorizationEpoch else { throw CancellationError() }
        return result
    }

    func refreshAvailability() async throws {
        availability = try await checkedAvailability()
    }

    func enable() async throws {
        try await refreshAvailability()
        if usesLocalMode {
            guard ready else { throw FanClientError(message: localSetupMessage) }
            return
        }
        let service = SMAppService.daemon(plistName: FanServiceIdentity.daemonPlist)
        if service.status == .notRegistered { try service.register() }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw FanClientError(message: "请在系统设置中允许 Ermi 后台服务，然后再次启用控制。")
        }
        guard service.status == .enabled else { throw FanClientError(message: "控制服务尚未启用：\(service.status.rawValue)") }
    }
    func request(_ command: FanServiceCommand) async throws -> FanServiceReply {
        let start = ProcessInfo.processInfo.systemUptime
        var authorizedAt: Double?
        var sentAt: Double?
        var succeeded = false
        let commandName: String
        switch command {
        case .inspect: commandName = "inspect"
        case .heartbeat: commandName = "heartbeat"
        case .restore: commandName = "restore"
        case .apply: commandName = "apply"
        }
        defer {
            let end = ProcessInfo.processInfo.systemUptime
            // XPC 握手发生在发送后的等待中；setup 只表示本地连接对象准备，不能冒充握手耗时。
            onTiming(.init(command: commandName, authorizationMS: ((authorizedAt ?? end) - start) * 1000,
                           connectionSetupMS: authorizedAt.map { ((sentAt ?? end) - $0) * 1000 } ?? 0,
                           replyMS: sentAt.map { (end - $0) * 1000 } ?? 0,
                           totalMS: (end - start) * 1000, succeeded: succeeded))
        }
        // 每一次请求重新验证客户端、helper 和 root 保护的授权文件，不能用界面缓存跳过安全检查。
        let checked = try await checkedAvailability()
        authorizedAt = ProcessInfo.processInfo.systemUptime
        availability = checked
        guard let serviceName = checked.serviceName, let requirement = checked.requirement else {
            throw FanClientError(message: checked.message)
        }
        let identity = serviceName + requirement
        if connectionIdentity != identity { resetConnection() }
        if connection == nil {
            let token = UUID(); generation = token
            let value = NSXPCConnection(machServiceName: serviceName, options: .privileged)
            value.remoteObjectInterface = NSXPCInterface(with: FanServiceProtocol.self)
            value.setCodeSigningRequirement(requirement)
            value.invalidationHandler = { [weak self] in Task { @MainActor in if self?.generation == token { self?.connection = nil } } }
            value.resume(); connection = value; connectionIdentity = identity
        }
        guard let connection else { throw FanClientError(message: "无法连接控制服务") }
        let token = generation
        let data = try JSONEncoder().encode(command)
        sentAt = ProcessInfo.processInfo.systemUptime
        let reply: FanServiceReply = try await withCheckedThrowingContinuation { continuation in
            let pending = PendingFanReply(continuation)
            // XPC 在自己的后台队列回调；显式 Sendable 避免继承此处 MainActor，
            // 否则服务未就绪/断连时会先触发隔离断言而闪退。这里只操作加锁的一次性回复。
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in pending.finish(.failure(error)) }
            guard let service = proxy as? FanServiceProtocol else {
                pending.finish(.failure(FanClientError(message: "控制服务接口不可用"))); return
            }
            service.request(data) { @Sendable data in
                do { pending.finish(.success(try JSONDecoder().decode(FanServiceReply.self, from: data))) }
                catch { pending.finish(.failure(error)) }
            }
            // 超时后不推测写入结果；断开触发helper恢复，租约也是独立后备机制。
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if pending.finish(.failure(FanClientError(message: "控制请求超时，等待服务恢复系统控制。"))) {
                    if self?.generation == token { self?.disconnect() }
                }
            }
        }
        succeeded = true
        return reply
    }
    private func resetConnection() {
        generation = UUID(); connection?.invalidate(); connection = nil; connectionIdentity = nil
    }
    func disconnect() { authorizationEpoch = UUID(); resetConnection() }
}
