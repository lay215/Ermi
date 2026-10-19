import Foundation
import Testing
import ErmiCore
@testable import ErmiFanHelper

private actor PausedFanDevice: FanDevice {
    private var mode = FanDeviceMode.system
    private var rpm = 3000.0
    private var pauseSnapshot = false
    private var snapshotWaiter: CheckedContinuation<Void, Never>?
    private var restoreWaiter: CheckedContinuation<Void, Never>?
    private(set) var restores = 0
    private(set) var writes = 0
    var snapshotPaused: Bool { snapshotWaiter != nil }
    var restorePaused: Bool { restoreWaiter != nil }
    func pauseNextSnapshot() { pauseSnapshot = true }
    func resumeSnapshot() { snapshotWaiter?.resume(); snapshotWaiter = nil }
    func resumeRestore() { restoreWaiter?.resume(); restoreWaiter = nil }
    func capabilities() -> [FanCapability] { [.init(index: 0, name: "测试", minimumRPM: 1200, maximumRPM: 6000)] }
    func snapshot() async -> FanDeviceSnapshot {
        if pauseSnapshot {
            pauseSnapshot = false
            await withCheckedContinuation { snapshotWaiter = $0 }
        }
        return .init(fans: [.init(index: 0, mode: mode, targetRPM: rpm, actualRPM: rpm)], cpuTemperature: 50, gpuTemperature: 50, sampledAt: ProcessInfo.processInfo.systemUptime)
    }
    func setManualRPM(index: Int, rpm: Double) { writes += 1; mode = .manual; self.rpm = rpm }
    func restoreSystem(index: Int) async {
        restores += 1
        await withCheckedContinuation { restoreWaiter = $0 }
        mode = .system
    }
}

struct ServiceRuntimeTests {
    @Test func applyWaitsForPeriodicTickInsteadOfReturningBusy() async throws {
        let device = PausedFanDevice()
        let runtime = ServiceRuntime(device: device)
        let owner = UUID(), life = SessionLife()
        let first = FanPreset(name: "初始", configuration: .fixed(rpm: 3200))
        _ = await runtime.execute(.apply(first), client: owner, life: life)
        await device.pauseNextSnapshot()
        let tick = Task { await runtime.tick() }
        for _ in 0..<500 { if await device.snapshotPaused { break }; await Task.yield() }
        try #require(await device.snapshotPaused)
        let next = FanPreset(name: "新选择", configuration: .fixed(rpm: 4000))
        let apply = Task { await runtime.execute(.apply(next), client: owner, life: life) }
        for _ in 0..<100 { await Task.yield() }
        #expect(await device.writes == 1)
        await device.resumeSnapshot()
        await tick.value
        let result = await apply.value
        #expect(result.error == nil)
        #expect(result.status.preset?.id == next.id)
        #expect(await device.writes == 2)
    }

    @Test func waitingApplyCannotTakeControlAfterConnectionCloses() async throws {
        let device = PausedFanDevice()
        let runtime = ServiceRuntime(device: device)
        let owner = UUID(), life = SessionLife()
        let preset = FanPreset(name: "初始", configuration: .fixed(rpm: 3200))
        _ = await runtime.execute(.apply(preset), client: owner, life: life)
        await device.pauseNextSnapshot()
        let tick = Task { await runtime.tick() }
        for _ in 0..<500 { if await device.snapshotPaused { break }; await Task.yield() }
        try #require(await device.snapshotPaused)
        let apply = Task { await runtime.execute(.apply(preset), client: owner, life: life) }
        for _ in 0..<100 { await Task.yield() }
        life.close()
        await device.resumeSnapshot()
        await tick.value
        let result = await apply.value
        #expect(result.error != nil)
        #expect(await device.writes == 1)
    }

    @Test func restoreWaitsForTickAndCoalescesDisconnectWithoutLosingOwner() async throws {
        let device = PausedFanDevice()
        let runtime = ServiceRuntime(device: device)
        let owner = UUID(), stranger = UUID()
        let life = SessionLife()
        let preset = FanPreset(name: "测试", configuration: .fixed(rpm: 4000))
        let applied = await runtime.execute(.apply(preset), client: owner, life: life)
        #expect(applied.status.phase == .applied)
        await device.pauseNextSnapshot()
        let tick = Task { await runtime.tick() }
        for _ in 0..<500 { if await device.snapshotPaused { break }; await Task.yield() }
        try #require(await device.snapshotPaused)

        let restore1 = Task { await runtime.execute(.restore, client: owner, life: life) }
        let restore2 = Task { await runtime.execute(.restore, client: owner, life: life) }
        let disconnect = Task { await runtime.disconnected(owner) }
        // tick 暂停时合法恢复应排队；其他连接不能借恢复请求取得控制权。
        for _ in 0..<100 { await Task.yield() }
        let denied = await runtime.execute(.restore, client: stranger, life: SessionLife())
        #expect(denied.error == "另一个 Ermi 连接正在控制风扇")
        await device.resumeSnapshot()
        for _ in 0..<500 { if await device.restorePaused { break }; await Task.yield() }
        try #require(await device.restorePaused)
        let blocked = await runtime.execute(.apply(preset), client: owner, life: life)
        #expect(blocked.error != nil)
        await runtime.tick()
        #expect(await device.writes == 1)
        #expect(await device.restores == 1)
        await device.resumeRestore()
        let result1 = await restore1.value, result2 = await restore2.value
        await disconnect.value
        await tick.value
        #expect(result1.error == nil)
        #expect(result2.error == nil)
        #expect(result1.status.phase == .system)
        #expect(result2.status.phase == .system)
        #expect(await device.restores == 1)
        // 恢复确认后才允许下一连接接管；旧恢复等待者不能释放新租约。
        let next = await runtime.execute(.apply(preset), client: stranger, life: SessionLife())
        #expect(next.status.phase == .applied)
        let oldOwner = await runtime.execute(.restore, client: owner, life: life)
        #expect(oldOwner.error == "另一个 Ermi 连接正在控制风扇")
    }
}
