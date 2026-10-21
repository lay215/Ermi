import Foundation
import ErmiCore

/// 单个连接独占一次控制租约；恢复可打断当前轮次，但不能被新 apply 或 tick 越过。
actor ServiceRuntime {
    let device: any FanDevice
    private let controller: FanController
    private var owner: UUID?
    private var operation: UUID?
    private var recovery: (id: UUID, task: Task<FanControlStatus, Never>)?
    private var shuttingDown = false
    private var ticking = false
    private var tickWaiters: [CheckedContinuation<Void, Never>] = []
    private var recoveryRevision = 0

    init(device: any FanDevice = SMCFanDevice()) {
        self.device = device
        self.controller = FanController(device: device)
    }

    func execute(_ command: FanServiceCommand, client: UUID, life: SessionLife) async -> FanServiceReply {
        guard life.isAlive, !shuttingDown else { return .init(error: "连接已关闭或服务正在退出") }
        switch command {
        case .inspect:
            // 明确返回能力探测结果：0只风扇属于正常硬件，协议缺失属于不可控制，均不伪装成连接故障。
            do {
                return .init(capabilities: try await device.capabilities(), status: await controller.status(), capabilityProbeCompleted: true, supportsTemperatureSensorSelection: true)
            } catch {
                return .init(status: await controller.status(), error: "风扇控制不可用：\(error)", capabilityProbeCompleted: true, supportsTemperatureSensorSelection: true)
            }
        case .apply(let preset):
            guard owner == nil || owner == client else { return .init(error: "另一个 Ermi 连接正在控制风扇") }
            guard recovery == nil else { return .init(error: "正在恢复系统控制，请恢复完成后重新选择模式") }
            // 定时采样不是用户操作冲突：等当前轮次结束再应用，避免正常切换被拒绝。
            // 等待期间若断连、退出或发生恢复，必须放弃旧选择，不能重新接管。
            let revision = recoveryRevision
            while ticking {
                await withCheckedContinuation { tickWaiters.append($0) }
            }
            guard life.isAlive, !shuttingDown else { return .init(error: "连接已关闭或服务正在退出") }
            guard revision == recoveryRevision else { return .init(error: "控制状态已变化，请重新选择模式") }
            guard owner == nil || owner == client else { return .init(error: "另一个 Ermi 连接正在控制风扇") }
            guard operation == nil, recovery == nil else { return .init(error: "正在处理上一条控制请求") }
            let token = UUID(); operation = token
            defer { if operation == token { operation = nil } }
            owner = client
            let status = await controller.apply(preset, leaseID: client, now: ProcessInfo.processInfo.systemUptime)
            releaseOwnerIfRestored(status)
            return .init(status: status)
        case .heartbeat:
            if owner == client, recovery == nil { _ = await controller.heartbeat(leaseID: client, now: ProcessInfo.processInfo.systemUptime) }
            return .init(status: await controller.status())
        case .restore:
            guard owner == nil || owner == client else { return .init(error: "另一个 Ermi 连接正在控制风扇") }
            // 不能因 tick 正在采样就拒绝恢复：控制器会等本轮结束并确认硬件恢复。
            return .init(status: await restore())
        }
    }

    private func releaseOwnerIfRestored(_ result: FanControlStatus) {
        // 恢复任务仍在等待时保留 owner，避免其他连接抢入或改变授权判断。
        if recovery == nil, result.phase == .system || result.phase == .failed { owner = nil }
    }

    private func restore() async -> FanControlStatus {
        // 多次恢复、连接中断和退出共享同一次恢复；后到的等待者不能清除新任务的状态。
        if let recovery { return await recovery.task.value }
        recoveryRevision += 1
        let id = UUID()
        let task = Task { await controller.restoreSystem() }
        recovery = (id, task)
        let result = await task.value
        if recovery?.id == id {
            recovery = nil
            releaseOwnerIfRestored(result)
        }
        return result
    }

    func disconnected(_ client: UUID) async {
        guard owner == client else { return }
        _ = await restore()
    }
    func tick() async {
        guard operation == nil, recovery == nil, !shuttingDown else { return }
        let token = UUID(); operation = token
        ticking = true
        defer {
            if operation == token { operation = nil }
            ticking = false
            let waiters = tickWaiters; tickWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let result = await controller.tick(now: ProcessInfo.processInfo.systemUptime)
        releaseOwnerIfRestored(result)
    }
    func shutdown() async -> Bool {
        shuttingDown = true
        let result = await restore()
        return result.phase == .system || result.phase == .failed
    }
}
// 失联标记同步设置，防已排队的apply在invalidation之后才开始接管。
final class SessionLife: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return !closed }
    func close() { lock.lock(); closed = true; lock.unlock() }
}
