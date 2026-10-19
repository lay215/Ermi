import Testing
import Foundation
import Darwin
@testable import ErmiCore

struct ProcessSignalerTests {
    // 测试只启动并结束本测试创建的 sleep，不操作任何现存用户应用。
    private func child() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test func terminatesOnlyCreatedChild() async throws {
        let process = try child()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let sampler = SystemSampler()
        let sample = try #require(await sampler.sample().processes.first { $0.pid == process.processIdentifier })
        try await ProcessSignaler(sampler: sampler).send(process: sample, force: false)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }

    @Test func forceTerminatesCreatedChild() async throws {
        let process = try child()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let sampler = SystemSampler()
        let sample = try #require(await sampler.sample().processes.first { $0.pid == process.processIdentifier })
        try await ProcessSignaler(sampler: sampler).send(process: sample, force: true)
        process.waitUntilExit()
        #expect(process.terminationStatus == SIGKILL)
    }

    @Test func rejectsStaleIdentityWithoutSignaling() async throws {
        let process = try child()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let sampler = SystemSampler()
        let sample = try #require(await sampler.sample().processes.first { $0.pid == process.processIdentifier })
        let stale = ProcessSample(id: ProcessIdentity(pid: sample.pid, startSeconds: sample.id.startSeconds + 1, startMicroseconds: sample.id.startMicroseconds), name: sample.name, cpuPercent: nil, memoryBytes: sample.memoryBytes, parentPID: sample.parentPID)
        await #expect(throws: ProcessSignalError.staleIdentity) {
            try await ProcessSignaler(sampler: sampler).send(process: stale, force: true)
        }
        #expect(process.isRunning)
    }

    @Test func rejectsSelfAndAncestorsWithoutSignaling() async throws {
        let sampler = SystemSampler()
        let current = try #require(await sampler.sample().processes.first { $0.pid == getpid() })
        await #expect(throws: ProcessSignalError.protectedProcess) {
            try await ProcessSignaler(sampler: sampler).send(process: current, force: true)
        }
        let ancestors = try await sampler.protectedProcessIDs()
        #expect(ancestors.contains(getpid()))
        #expect(ancestors.contains(getppid()))
        let parent = ProcessSample(id: ProcessIdentity(pid: getppid(), startSeconds: 0, startMicroseconds: 0), name: "parent", cpuPercent: nil, memoryBytes: 0, parentPID: 1)
        await #expect(throws: ProcessSignalError.protectedProcess) {
            try await ProcessSignaler(sampler: sampler).send(process: parent, force: false)
        }
    }
}
