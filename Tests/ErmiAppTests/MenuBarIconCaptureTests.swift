import AppKit
import Testing
@testable import Ermi

@MainActor
struct MenuBarIconCaptureTests {
    private let frame = CGRect(x: 800, y: 0, width: 24, height: 24)

    private func window(
        _ id: CGWindowID = 1, pid: pid_t = 42, frame: CGRect? = nil,
        layer: Int = Int(CGWindowLevelForKey(.statusWindow))
    ) -> MenuBarIconCapture.WindowCandidate {
        .init(id: id, pid: pid, frame: frame ?? self.frame, layer: layer)
    }

    private func image(
        width: Int = 48, height: Int = 48, opaqueBackground: Bool = false,
        content: CGRect? = nil, cutout: CGRect? = nil
    ) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if opaqueBackground {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let content {
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
            context.fill(content)
        }
        if let cutout { context.clear(cutout) }
        return try #require(context.makeImage())
    }

    @Test func requiresUniquePIDAndAllFourFrameEdges() {
        let foreign = window(2, pid: 99)
        let overlapping = window(3, frame: frame.offsetBy(dx: 8, dy: 0))
        #expect(MenuBarIconCapture.uniqueWindowID(pid: 42, frame: frame, windows: [foreign, overlapping, window()]) == 1)
        #expect(MenuBarIconCapture.uniqueWindowID(pid: 42, frame: frame, windows: [foreign, overlapping]) == nil)
        #expect(MenuBarIconCapture.uniqueWindowID(pid: 42, frame: frame, windows: [window(), window(4)]) == nil)
        #expect(MenuBarIconCapture.uniqueWindowID(pid: 42, frame: nil, windows: [window()]) == nil)
    }

    @Test func toleratesPixelRoundingButRejectsUnknownOrLargeWindows() {
        #expect(MenuBarIconCapture.uniqueWindowID(
            pid: 42, frame: frame, windows: [window(frame: frame.insetBy(dx: -0.5, dy: -0.5))]
        ) == 1)
        let oversized = CGRect(x: 800, y: 0, width: 800, height: 600)
        #expect(MenuBarIconCapture.uniqueWindowID(
            pid: 42, frame: oversized, windows: [window(frame: oversized)]
        ) == nil)
        #expect(MenuBarIconCapture.uniqueWindowID(pid: 0, frame: frame, windows: [window(pid: 0)]) == nil)
        #expect(MenuBarIconCapture.uniqueWindowID(
            pid: 42, frame: CGRect(x: CGFloat.nan, y: 0, width: 24, height: 24), windows: [window()]
        ) == nil)
        #expect(MenuBarIconCapture.uniqueWindowID(
            pid: 42, frame: frame, windows: [window(layer: Int(CGWindowLevelForKey(.floatingWindow)))]
        ) == nil)
    }

    @Test func trimsTransparentPaddingAndRetainsRetinaPointSize() throws {
        let source = try image(
            content: CGRect(x: 12, y: 8, width: 20, height: 28),
            cutout: CGRect(x: 16, y: 12, width: 12, height: 20)
        )
        let result = try #require(MenuBarIconCapture.templateImage(from: source, scale: 2))
        #expect(result.isTemplate)
        #expect(result.size == NSSize(width: 10, height: 14))
        var proposed = CGRect(origin: .zero, size: result.size)
        let pixels = try #require(result.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        #expect(pixels.width == 20)
        #expect(pixels.height == 28)
    }

    @Test func opaqueAndEmptyImagesUseFallback() throws {
        let opaque = try image(opaqueBackground: true, content: CGRect(x: 8, y: 8, width: 32, height: 32))
        let empty = try image()
        #expect(MenuBarIconCapture.templateImage(from: opaque, scale: 2) == nil)
        #expect(MenuBarIconCapture.templateImage(from: empty, scale: 2) == nil)
        #expect(MenuBarIconCapture.templateImage(from: empty, scale: 0) == nil)
        let insetRectangle = try image(content: CGRect(x: 1, y: 1, width: 46, height: 46))
        #expect(MenuBarIconCapture.templateImage(from: insetRectangle, scale: 2) == nil)
        let context = try #require(CGContext(
            data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 48 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let noAlpha = try #require(context.makeImage())
        #expect(MenuBarIconCapture.templateImage(from: noAlpha, scale: 2) == nil)
    }

    @Test func timeoutReturnsPartialImagesWithoutWaitingForUncooperativeOperation() async throws {
        let session = MenuBarIconCapture.CaptureSession()
        let id = UUID()
        let earlyImage = NSImage(size: NSSize(width: 8, height: 8))
        var release: CheckedContinuation<Void, Never>?
        let result = await session.run(timeout: .milliseconds(20)) { session in
            session.store(earlyImage, for: id)
            // 不响应 Task.cancel 的挂起操作模拟系统 API；测试主动释放，避免遗留任务。
            await withCheckedContinuation { release = $0 }
            session.store(NSImage(size: NSSize(width: 20, height: 20)), for: UUID())
        }
        #expect(session.isFinished)
        #expect(result.count == 1)
        #expect(result[id] === earlyImage)
        try #require(release).resume()
        await Task.yield()
        #expect(result.count == 1)
    }

    @Test func callerCancellationDiscardsPartialImagesAndLateCompletion() async throws {
        let session = MenuBarIconCapture.CaptureSession()
        var release: CheckedContinuation<Void, Never>?
        let task = Task {
            await session.run(timeout: .seconds(10)) { session in
                session.store(NSImage(size: NSSize(width: 8, height: 8)), for: UUID())
                await withCheckedContinuation { release = $0 }
                session.store(NSImage(size: NSSize(width: 10, height: 10)), for: UUID())
            }
        }
        while release == nil { await Task.yield() }
        task.cancel()
        let result = await task.value
        #expect(result.isEmpty)
        #expect(session.isFinished)
        try #require(release).resume()
        await Task.yield()
    }
}
