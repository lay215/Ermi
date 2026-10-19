import Foundation
import Testing
import ErmiCore
@testable import Ermi

// 模拟签名服务长时间同步等待：测试主线程能在校验结束前处理输入，而不是只比较动画时长。
private final class SignatureCheckGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var callCount = 0
    private var mainThread = false
    var calls: Int { lock.withLock { callCount } }
    var ranOnMain: Bool { lock.withLock { mainThread } }
    func check() -> FanClientAvailability {
        lock.withLock { callCount += 1; mainThread = Thread.isMainThread }
        _ = release.wait(timeout: .now() + 2)
        return .init(usesLocalMode: true, message: "测试授权", serviceName: "test.invalid", requirement: "test")
    }
    func finish() { release.signal() }
}

private final class RevokingAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func check() -> FanClientAvailability {
        lock.withLock {
            count += 1
            if count > 1 { return .init(usesLocalMode: true, message: "授权已撤销") }
            return .init(usesLocalMode: true, message: "测试授权",
                         serviceName: "app.ermi.test.missing." + UUID().uuidString,
                         requirement: "identifier \"app.ermi.test.missing\"")
        }
    }
}

@MainActor
struct FanClientResponsivenessTests {
    @Test func eachRequestValidatesOnceAndRevocationRejectsNextWrite() async {
        let authorization = RevokingAuthorization()
        var timings: [FanRequestTiming] = []
        let client = FanControlClient(checkAuthorization: { authorization.check() }, onTiming: { timings.append($0) })
        defer { client.disconnect() }
        _ = try? await client.request(.inspect)
        #expect(authorization.calls == 1)
        #expect(client.ready)
        // 前次校验通过不能成为下一次写请求的缓存授权；撤销后必须在 XPC 发送前拒绝。
        do {
            _ = try await client.request(.apply(.init(name: "测试", configuration: .fixed(rpm: 3200))))
            Issue.record("已撤销的授权不得用于调速")
        } catch { #expect(error.localizedDescription == "授权已撤销") }
        #expect(authorization.calls == 2)
        #expect(!client.ready)
        #expect(timings.count == 2)
        #expect(timings.last?.command == "apply")
        #expect(timings.last?.replyMS == 0)
        #expect(timings.allSatisfy { !$0.succeeded && $0.totalMS >= $0.authorizationMS })
    }

    @Test func unavailableServiceReturnsErrorWithoutCrashing() async {
        // 使用真实 XPC 的后台错误回调重现启动时服务尚不可用，不连接实际风扇设备。
        let serviceName = "app.ermi.test.missing." + UUID().uuidString
        let client = FanControlClient(checkAuthorization: {
            .init(usesLocalMode: true, message: "测试授权", serviceName: serviceName,
                  requirement: "identifier \"app.ermi.test.missing\"")
        })
        defer { client.disconnect() }
        do {
            _ = try await client.request(.inspect)
            Issue.record("不存在的服务必须返回连接错误")
        } catch {
            #expect((error as NSError).domain == NSCocoaErrorDomain)
            #expect((error as NSError).code == NSXPCConnectionInvalid)
        }
    }

    @Test func synchronousSignatureWaitDoesNotBlockMainActor() async throws {
        let gate = SignatureCheckGate()
        let client = FanControlClient(checkAuthorization: { gate.check() })
        let pending = Task { try await client.refreshAvailability() }
        defer { gate.finish() }
        for _ in 0..<100 where gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        // 校验仍在等待时，本测试已经返回 MainActor，且界面读取不触发新的签名 I/O。
        #expect(gate.calls == 1)
        #expect(!gate.ranOnMain)
        #expect(!client.ready)
        #expect(client.localSetupMessage == "正在检查控制授权…")
        gate.finish()
        try await pending.value
        #expect(client.ready)
    }

    @Test func disconnectInvalidatesInFlightRequestBeforeAnyXPCConnection() async throws {
        let gate = SignatureCheckGate()
        let client = FanControlClient(checkAuthorization: { gate.check() })
        let pending = Task { try await client.request(.inspect) }
        defer { gate.finish() }
        for _ in 0..<100 where gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.calls == 1)
        client.disconnect()
        gate.finish()
        do {
            _ = try await pending.value
            Issue.record("旧授权检查在断连后仍发起了请求")
        } catch is CancellationError { }
        catch { Issue.record("应在 XPC 建连前取消，实际错误：\(error)") }
        #expect(!client.ready)
    }

    @Test func cancelledRefreshCannotPublishStaleAuthorization() async throws {
        let gate = SignatureCheckGate()
        let client = FanControlClient(checkAuthorization: { gate.check() })
        let pending = Task { try await client.refreshAvailability() }
        defer { gate.finish() }
        for _ in 0..<100 where gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        pending.cancel()
        gate.finish()
        do {
            try await pending.value
            Issue.record("取消后的授权检查不应更新界面")
        } catch is CancellationError { }
        catch { Issue.record("错误类型不正确：\(error)") }
        #expect(!client.ready)
    }
}
