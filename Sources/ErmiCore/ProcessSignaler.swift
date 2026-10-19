import Foundation
import Darwin

public enum ProcessSignalError: Error, LocalizedError, Sendable, Equatable {
    case protectedProcess, staleIdentity, unverifiableAncestry
    case systemError(Int32)
    public var errorDescription: String? {
        switch self {
        case .protectedProcess: "Ermi 和维持其运行的进程不能在这里结束。"
        case .staleIdentity: "进程已退出或身份发生变化，请刷新后重试。"
        case .unverifiableAncestry: "无法核实进程保护范围，请稍后重试。"
        case .systemError(let code): "系统拒绝结束进程（错误 \(code)）。"
        }
    }
}

public actor ProcessSignaler {
    private let sampler: SystemSampler
    public init(sampler: SystemSampler) { self.sampler = sampler }

    public func validate(process: ProcessSample) async throws {
        // 从内核逐级查询祖先，保护不受列表筛选、权限缺项或旧快照影响。
        let protected = try await sampler.protectedProcessIDs()
        guard process.pid > 1, !protected.contains(process.pid) else { throw ProcessSignalError.protectedProcess }
        // identity() 同时核对当前 UID；临近发送再核对 PID + 启动时间，降低 PID 复用风险。
        guard await sampler.identity(for: process.pid) == process.id else { throw ProcessSignalError.staleIdentity }
    }

    public func send(process: ProcessSample, force: Bool) async throws {
        try await validate(process: process)
        guard kill(process.pid, force ? SIGKILL : SIGTERM) == 0 else { throw ProcessSignalError.systemError(errno) }
        // 系统接受信号不等于进程已退出，调用方继续采样观察实际状态。
    }
}
