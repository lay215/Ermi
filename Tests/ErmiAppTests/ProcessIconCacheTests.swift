import AppKit
import ErmiCore
import Testing
@testable import Ermi

@MainActor
struct ProcessIconCacheTests {
    private func identity(_ start: UInt64 = 10) -> ProcessIdentity {
        ProcessIdentity(pid: 123, startSeconds: start, startMicroseconds: 42)
    }

    @Test func repeatedRenderingResolvesOnceAndEventuallyRefreshes() {
        let cache = ProcessIconCache()
        let first = NSImage(size: NSSize(width: 16, height: 16))
        let updated = NSImage(size: NSSize(width: 32, height: 32))
        var queries = 0
        // 模拟动画逐帧与每秒采样：包括通用占位图在内，同一身份短期内只解析一次。
        for frame in 0..<300 {
            let image = cache.image(identity: identity(), name: "App", now: Double(frame) / 60) {
                queries += 1
                return first
            }
            #expect(image === first)
        }
        #expect(queries == 1)
        let image = cache.image(identity: identity(), name: "App", now: 5) {
            queries += 1
            return updated
        }
        #expect(image === updated)
        #expect(queries == 2)
    }

    @Test func reusedPIDAndRenamedExecutableResolveIndependently() {
        let cache = ProcessIconCache()
        let old = NSImage(size: NSSize(width: 16, height: 16))
        let new = NSImage(size: NSSize(width: 32, height: 32))
        _ = cache.image(identity: identity(), name: "App", now: 0) { old }
        let reused = cache.image(identity: identity(11), name: "App", now: 1) { new }
        let renamed = cache.image(identity: identity(), name: "Other", now: 1) { new }
        #expect(reused === new)
        #expect(renamed === new)
    }

    @Test func processChurnEvictsOldestEntry() {
        let cache = ProcessIconCache(capacity: 2)
        let old = NSImage(size: NSSize(width: 16, height: 16))
        let refreshed = NSImage(size: NSSize(width: 32, height: 32))
        for index in 0..<3 {
            _ = cache.image(identity: identity(UInt64(index)), name: "App", now: Double(index)) { old }
        }
        let kept = cache.image(identity: identity(1), name: "App", now: 3) { refreshed }
        let evicted = cache.image(identity: identity(0), name: "App", now: 3) { refreshed }
        #expect(kept === old)
        #expect(evicted === refreshed)
    }
}
