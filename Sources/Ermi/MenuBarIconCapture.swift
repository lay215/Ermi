import AppKit
import CoreVideo
@preconcurrency import ScreenCaptureKit

@MainActor
enum MenuBarIconCapture {
    struct WindowCandidate {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let layer: Int
    }

    static func capture(_ entries: [MenuBarTrayEntry]) async -> [UUID: NSImage] {
        // 读取可捕获窗口本身也受录屏权限约束；这里只检查现有授权，绝不隐式请求授权。
        guard !entries.isEmpty, !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return [:] }
        let session = CaptureSession()
        return await session.run(timeout: .milliseconds(1_500)) { session in
            guard !session.isFinished, CGPreflightScreenCaptureAccess() else { return }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            ), !Task.isCancelled, !session.isFinished else { return }

            let candidates = content.windows.compactMap { window -> WindowCandidate? in
                guard let owner = window.owningApplication else { return nil }
                return WindowCandidate(
                    id: window.windowID, pid: owner.processID, frame: window.frame, layer: window.windowLayer
                )
            }
            let matches = entries.compactMap { entry -> (MenuBarTrayEntry, CGWindowID)? in
                guard let id = uniqueWindowID(pid: entry.pid, frame: entry.frame, windows: candidates) else { return nil }
                return (entry, id)
            }
            let matchCounts = Dictionary(grouping: matches, by: { $0.1 }).mapValues(\.count)
            for (entry, windowID) in matches {
                guard !Task.isCancelled, !session.isFinished, CGPreflightScreenCaptureAccess() else { return }
                // 多个 AX 入口指向同一个窗口时，无法确认单个 glyph 的范围，宁可保留占位。
                guard matchCounts[windowID] == 1,
                      let window = content.windows.first(where: { $0.windowID == windowID }) else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = CGFloat(filter.pointPixelScale)
                let rect = filter.contentRect
                guard scale.isFinite, (1...4).contains(scale), isMenuBarSized(rect) else { continue }
                let configuration = SCStreamConfiguration()
                configuration.width = Int(ceil(rect.width * scale))
                configuration.height = Int(ceil(rect.height * scale))
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = false
                // backgroundColor 的系统默认值是透明；不传临时 CGColor，避免其 assign 属性悬空。
                configuration.shouldBeOpaque = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.ignoreGlobalClipSingleWindow = true
                if #available(macOS 14.2, *) { configuration.includeChildWindows = false }

                guard let original = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration
                ), !Task.isCancelled, !session.isFinished,
                      let image = templateImage(from: original, scale: scale) else { continue }
                session.store(image, for: entry.id)
            }
        }
    }

    static func uniqueWindowID(pid: pid_t, frame: CGRect?, windows: [WindowCandidate]) -> CGWindowID? {
        guard pid > 0, let frame, isMenuBarSized(frame) else { return nil }
        // PID、状态栏窗口层和 AX 四边界必须同时匹配；不能用交集或最近窗口猜测，避免截到正文或弹出菜单。
        let matches = windows.filter { window in
            window.pid == pid && window.layer == Int(CGWindowLevelForKey(.statusWindow)) && isMenuBarSized(window.frame)
                && abs(window.frame.minX - frame.minX) <= 1
                && abs(window.frame.minY - frame.minY) <= 1
                && abs(window.frame.maxX - frame.maxX) <= 1
                && abs(window.frame.maxY - frame.maxY) <= 1
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func isMenuBarSized(_ frame: CGRect) -> Bool {
        // 较宽的状态文字也可保留；超出这一保守范围的窗口不作为菜单栏图标捕获。
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && (1...512).contains(frame.width) && (12...64).contains(frame.height)
    }

    static func templateImage(from original: CGImage, scale: CGFloat) -> NSImage? {
        guard scale.isFinite, (1...4).contains(scale),
              original.width > 1, original.height > 1,
              original.width <= 2_048, original.height <= 256 else { return nil }
        switch original.alphaInfo {
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly: break
        default: return nil
        }
        let width = original.width
        let height = original.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let normalized: CGImage? = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }
            context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        guard let normalized else { return nil }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[y * rowBytes + x * 4 + 3] }
        // 截图带有不透明背景时，template 会变成实心矩形。只接受四角透明且至少 90% 边缘透明的图像。
        guard alpha(0, 0) <= 1, alpha(width - 1, 0) <= 1,
              alpha(0, height - 1) <= 1, alpha(width - 1, height - 1) <= 1 else { return nil }
        var transparentEdges = 0
        for x in 0..<width {
            if alpha(x, 0) <= 1 { transparentEdges += 1 }
            if alpha(x, height - 1) <= 1 { transparentEdges += 1 }
        }
        for y in 1..<(height - 1) {
            if alpha(0, y) <= 1 { transparentEdges += 1 }
            if alpha(width - 1, y) <= 1 { transparentEdges += 1 }
        }
        guard transparentEdges * 10 >= (width * 2 + (height - 2) * 2) * 9 else { return nil }

        var left = width, right = -1, top = height, bottom = -1
        var visiblePixels = 0
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > 1 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
                if alpha(x, y) > 8 { visiblePixels += 1 }
            }
        }
        // 透明外边距也可能围住一块实心窗口背景；裁剪后仍近乎填满的矩形不冒充真实 glyph。
        guard visiblePixels > 0, right >= left, bottom >= top,
              visiblePixels * 100 < (right - left + 1) * (bottom - top + 1) * 95,
              let cropped = normalized.cropping(to: CGRect(
                x: left, y: top, width: right - left + 1, height: bottom - top + 1
              )) else { return nil }
        // 去掉透明留白后仍按原屏幕倍率换算 point，防止 Retina 图标被放大一倍。
        let image = NSImage(cgImage: cropped, size: NSSize(
            width: CGFloat(cropped.width) / scale, height: CGFloat(cropped.height) / scale
        ))
        image.isTemplate = true
        return image
    }

    @MainActor
    final class CaptureSession {
        private(set) var isFinished = false
        private var images: [UUID: NSImage] = [:]
        private var continuation: CheckedContinuation<[UUID: NSImage], Never>?
        private var worker: Task<Void, Never>?
        private var deadline: Task<Void, Never>?

        func store(_ image: NSImage, for id: UUID) {
            guard !isFinished else { return }
            images[id] = image
        }

        func run(
            timeout: Duration,
            operation: @escaping @MainActor (CaptureSession) async -> Void
        ) async -> [UUID: NSImage] {
            let result: [UUID: NSImage] = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<[UUID: NSImage], Never>) in
                    guard !isFinished, !Task.isCancelled else {
                        isFinished = true
                        continuation.resume(returning: [:])
                        return
                    }
                    self.continuation = continuation
                    // 系统截图 await 不保证响应取消；独立任务配合一次性完成门闩，超时不等待底层返回。
                    worker = Task {
                        await operation(self)
                        finish()
                    }
                    deadline = Task {
                        do {
                            try await Task.sleep(for: timeout)
                            finish()
                        } catch {}
                    }
                }
            } onCancel: {
                Task { @MainActor in self.finish(discard: true) }
            }
            return Task.isCancelled ? [:] : result
        }

        private func finish(discard: Bool = false) {
            guard !isFinished else { return }
            isFinished = true
            worker?.cancel()
            deadline?.cancel()
            worker = nil
            deadline = nil
            let result = discard ? [:] : images
            images = [:]
            continuation?.resume(returning: result)
            continuation = nil
        }
    }
}
