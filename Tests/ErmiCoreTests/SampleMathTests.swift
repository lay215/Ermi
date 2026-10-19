import Testing
import Darwin
@testable import ErmiCore

struct SampleMathTests {
    @Test func cpuUsesDeltaAndExcludesIdle() {
        #expect(SampleMath.cpuPercent(previous: [100, 100, 100, 0], current: [120, 110, 170, 0]) == 30)
        #expect(SampleMath.cpuPercent(previous: [1, 2, 3, 4], current: [1, 2, 3, 4]) == nil)
        #expect(SampleMath.cpuPercent(previous: [], current: [1, 2, 3, 4]) == nil)
    }

    @Test func cpuCounterWraps() {
        let value = SampleMath.cpuPercent(previous: [UInt32.max - 1, 10, 10, 10], current: [1, 10, 13, 10])
        #expect(value == 50)
    }

    @Test func processCPUUsesSingleCoreScale() {
        #expect(SampleMath.processPercent(previous: 1_000_000_000, current: 5_000_000_000, elapsed: 2) == 200)
        #expect(SampleMath.processPercent(previous: 0, current: 24_000_000, elapsed: 1, timebaseNumer: 125, timebaseDenom: 3) == 100)
        #expect(SampleMath.processPercent(previous: 10, current: 9, elapsed: 1) == nil)
        #expect(SampleMath.processPercent(previous: 0, current: 10, elapsed: 0) == nil)
    }

    @Test func memoryDoesNotDoubleCountFileCache() {
        #expect(SampleMath.usedMemory(active: 100, inactive: 60, wired: 20, compressed: 10, purgeable: 5, external: 55, pageSize: 4096, total: 1_000_000) == 130 * 4096)
        #expect(SampleMath.usedMemory(active: 1, inactive: 0, wired: 0, compressed: 0, purgeable: 5, external: 10, pageSize: 4096, total: 1_000_000) == 0)
        #expect(SampleMath.usedMemory(active: 100, inactive: 0, wired: 0, compressed: 0, purgeable: 0, external: 0, pageSize: 4096, total: 1000) == 1000)
    }

    @Test func processIdentityIncludesStartTime() {
        #expect(ProcessIdentity(pid: 4, startSeconds: 1, startMicroseconds: 2) != ProcessIdentity(pid: 4, startSeconds: 2, startMicroseconds: 2))
    }

    @Test func liveSnapshotReadsMemoryAndOwnIdentity() async {
        let sampler = SystemSampler()
        let first = await sampler.sample()
        #expect(first.cpuPercent == nil)
        #expect(first.memory?.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(first.processes.contains { $0.pid == getpid() && $0.memoryBytes > 0 })
        let identity = await sampler.identity(for: getpid())
        #expect(identity?.pid == getpid())
        #expect(await sampler.identity(for: -1) == nil)
    }
}

import Foundation
