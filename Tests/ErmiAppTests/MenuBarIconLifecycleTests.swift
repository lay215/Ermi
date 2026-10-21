import AppKit
@preconcurrency import ApplicationServices
import Testing
@testable import Ermi

@MainActor
private final class IconLifecycleProbe {
    var accessibilityGranted = true
    var captureGranted = true
    var permissionAfterRequest = true
    private(set) var scans = 0
    private(set) var accessibilityRequests = 0
    private(set) var captureRequests = 0
    private(set) var capturedEntryIDs: [[UUID]] = []
    private(set) var actions: [(UUID, String)] = []
    var refreshes = 0
    let image: NSImage = {
        // 只验证图像归属与清理；内存模板不采集屏幕，也不读取第三方 App 图片。
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }()

    func makeTray(entries: [MenuBarTrayEntry],
                  capture: (([MenuBarTrayEntry]) async -> [UUID: NSImage])? = nil) -> MenuBarTray {
        let tray = MenuBarTray(
            permissionCheck: { self.accessibilityGranted },
            permissionRequest: {
                self.accessibilityRequests += 1
                return self.accessibilityGranted
            },
            identityCheck: { _, _ in true },
            scanOverride: {
                await MainActor.run {
                    self.scans += 1
                    return (entries, [:])
                }
            },
            actionOverride: { entry, action in
                await MainActor.run {
                    self.actions.append((entry.id, action))
                    return AXError.success.rawValue
                }
            },
            screenCapturePermissionCheck: { self.captureGranted },
            screenCapturePermissionRequest: {
                self.captureRequests += 1
                self.captureGranted = self.permissionAfterRequest
                return self.captureGranted
            },
            iconCaptureOverride: { selected in
                self.capturedEntryIDs.append(selected.map(\.id))
                if let capture { return await capture(selected) }
                return Dictionary(uniqueKeysWithValues: selected.map { ($0.id, self.image) })
            }
        )
        tray.onRefresh = { self.refreshes += 1 }
        return tray
    }
}

@MainActor
private final class SuspendedIconCapture {
    private var started = false
    private var finished = false
    private var result: CheckedContinuation<[UUID: NSImage], Never>?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func capture() async -> [UUID: NSImage] {
        started = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: true) }
        return await withCheckedContinuation { result = $0 }
    }

    func waitUntilStartedOrFinished() async -> Bool {
        if started { return true }
        if finished { return false }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func complete(images: [UUID: NSImage]) {
        result?.resume(returning: images)
        result = nil
    }

    func markFinished() {
        finished = true
        // 若错误地跳过取图，立即让测试失败；不能留下永远等不到采集开始的 continuation。
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: started) }
    }
}

@MainActor
struct MenuBarIconLifecycleTests {
    private func entry(_ name: String = "Hidden", bundle: String = "test.hidden", x: CGFloat = 20, pid: pid_t = -1,
                       icon: NSImage? = nil) -> MenuBarTrayEntry {
        // 无效 PID 仅构造 AX 类型占位，所有系统查询与动作均由替身承担。
        MenuBarTrayEntry(pid: pid, bundleID: bundle, name: name, label: name,
                         element: AXUIElementCreateApplication(pid), action: kAXShowMenuAction,
                         frame: CGRect(x: x, y: 0, width: 20, height: 24), icon: icon)
    }

    @Test func terminatingOneProcessPreservesOtherEntriesFromTheSameApp() async {
        let probe = IconLifecycleProbe()
        let exited = entry("Exited", x: 20, pid: -1)
        let surviving = entry("Surviving", x: 60, pid: -2)
        let tray = probe.makeTray(entries: [exited, surviving])
        defer { tray.close() }
        await tray.prepare(scope: .applications(["test.hidden"]))

        // bundle 仍在运行时，退出通知的 PID 只淘汰该进程，不能把同 App 的另一入口一起删除。
        tray.removeTerminatedEntries(running: ["test.hidden"], terminatedPID: -1)
        #expect(tray.entries.map(\.id) == [surviving.id])
        #expect(tray.entries.first?.icon === probe.image)
        await tray.activate(exited)
        #expect(probe.actions.isEmpty)
        await tray.activate(surviving)
        #expect(probe.actions.first?.0 == surviving.id)
        #expect(probe.scans == 1)
    }

    @Test func wideStatusGlyphRetainsHeightAndUsesActualRowWidth() {
        let wide = entry(icon: NSImage(size: NSSize(width: 96, height: 16)))
        let excessive = entry(icon: NSImage(size: NSSize(width: 512, height: 16)))
        let ordinary = entry()
        // 宽数字按 18pt 高度保留比例；超过一项可用宽度则降级，而不是缩成几像素高的文字。
        #expect(wide.displayIcon != nil)
        #expect(wide.iconWidth == 108)
        #expect(wide.buttonWidth == 120)
        #expect(excessive.displayIcon == nil)
        #expect(excessive.buttonWidth == ordinary.buttonWidth)
        let width = [wide, ordinary].reduce(0) { $0 + $1.buttonWidth + 4 }
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let row = MenuBarTray.layout(anchor: nil, screen: screen, visible: screen,
                                    entryCount: 2, showsMessage: false, entriesWidth: width)
        #expect(row.width == width + 52)
        #expect(row.height == 36)
    }

    @Test func fallbackBitmapRemovesColorAndPreservesTransparency() throws {
        let context = try #require(CGContext(
            data: nil, width: 36, height: 36, bitsPerComponent: 8, bytesPerRow: 36 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 20, height: 20))
        let source = NSImage(cgImage: try #require(context.makeImage()), size: NSSize(width: 36, height: 36))
        let gray = try #require(MenuBarTray.grayscaleIcon(source))
        var bounds = CGRect(origin: .zero, size: gray.size)
        let bitmap = NSBitmapImageRep(cgImage: try #require(gray.cgImage(forProposedRect: &bounds, context: nil, hints: nil)))
        let center = try #require(bitmap.colorAt(x: 18, y: 18)?.usingColorSpace(.sRGB))
        #expect(abs(center.redComponent - center.greenComponent) < 0.001)
        #expect(abs(center.greenComponent - center.blueComponent) < 0.001)
        #expect(center.alphaComponent > 0.99)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent < 0.01)
    }

    @Test func unavailableCapturePermissionStillAllowsAXWithoutAutomaticRequests() async {
        let probe = IconLifecycleProbe()
        probe.captureGranted = false
        let item = entry(icon: probe.image)
        let tray = probe.makeTray(entries: [item])
        defer { tray.close() }

        await tray.prepare(scope: .applications(["test.hidden"]))

        #expect(tray.authorized)
        #expect(!tray.screenCaptureAuthorized)
        #expect(tray.entries.map(\.id) == [item.id])
        #expect(tray.entries.allSatisfy { $0.icon == nil })
        #expect(probe.capturedEntryIDs.isEmpty)
        #expect(probe.captureRequests == 0)
        #expect(probe.accessibilityRequests == 0)
        await tray.activate(item)
        #expect(probe.actions.count == 1)
        #expect(probe.actions.first?.0 == item.id)
        #expect(probe.actions.first?.1 == kAXShowMenuAction)
        #expect(probe.captureRequests == 0)
        #expect(probe.capturedEntryIDs.isEmpty)
        #expect(probe.refreshes == 0)
    }

    @Test func captureOnlyReceivesEntriesInSelectedGroup() async {
        let probe = IconLifecycleProbe()
        let right = entry("Right", x: 70)
        let left = entry("Left", x: 10)
        let retained = entry("Retained", bundle: "test.retained", x: 0)
        let tray = probe.makeTray(entries: [right, retained, left])
        defer { tray.close() }

        await tray.prepare(scope: .applications(["test.hidden"]))

        // 过滤必须先于截图，同一 App 多入口保持逐项身份，常驻组不能被顺便采集。
        #expect(probe.capturedEntryIDs == [[left.id, right.id]])
        #expect(tray.entries.map(\.id) == [left.id, right.id])
        #expect(tray.entries.allSatisfy { $0.icon === probe.image && $0.icon?.isTemplate == true })
        #expect(probe.captureRequests == 0)
    }

    @Test func closeRejectsImagesFromInFlightCapture() async throws {
        let probe = IconLifecycleProbe()
        let capture = SuspendedIconCapture()
        let item = entry()
        let tray = probe.makeTray(entries: [item], capture: { _ in await capture.capture() })
        defer { tray.close() }
        let prepare = Task {
            await tray.prepare(scope: .applications(["test.hidden"]))
            capture.markFinished()
        }
        try #require(await capture.waitUntilStartedOrFinished())
        #expect(tray.loading)

        tray.close()
        capture.complete(images: [item.id: probe.image])
        await prepare.value

        #expect(tray.entries.isEmpty)
        #expect(!tray.loading)
        #expect(!tray.isPresented)
        #expect(probe.capturedEntryIDs == [[item.id]])
        #expect(probe.refreshes == 0)
    }

    @Test func captureRevocationDuringCaptureKeepsAXEntryWithoutImage() async throws {
        let probe = IconLifecycleProbe()
        let capture = SuspendedIconCapture()
        let item = entry()
        let tray = probe.makeTray(entries: [item], capture: { _ in await capture.capture() })
        defer { tray.close() }
        let prepare = Task {
            await tray.prepare(scope: .applications(["test.hidden"]))
            capture.markFinished()
        }
        try #require(await capture.waitUntilStartedOrFinished())

        probe.captureGranted = false
        tray.synchronizeIconPermission()
        capture.complete(images: [item.id: probe.image])
        await prepare.value

        #expect(tray.authorized)
        #expect(!tray.screenCaptureAuthorized)
        #expect(tray.entries.map(\.id) == [item.id])
        #expect(tray.entries.allSatisfy { $0.icon == nil })
        #expect(!tray.loading)
        await tray.activate(item)
        #expect(probe.actions.count == 1)
        #expect(probe.actions.first?.0 == item.id)
        #expect(probe.captureRequests == 0)
        #expect(probe.refreshes == 0)
    }

    @Test func accessibilityRevocationDuringCaptureRejectsEntriesAndImages() async throws {
        let probe = IconLifecycleProbe()
        let capture = SuspendedIconCapture()
        let item = entry()
        let tray = probe.makeTray(entries: [item], capture: { _ in await capture.capture() })
        defer { tray.close() }
        let prepare = Task {
            await tray.prepare(scope: .applications(["test.hidden"]))
            capture.markFinished()
        }
        try #require(await capture.waitUntilStartedOrFinished())

        probe.accessibilityGranted = false
        capture.complete(images: [item.id: probe.image])
        await prepare.value

        #expect(!tray.authorized)
        #expect(tray.entries.isEmpty)
        #expect(!tray.loading)
        await tray.activate(item)
        #expect(probe.actions.isEmpty)
        #expect(probe.accessibilityRequests == 0)
        #expect(probe.refreshes == 0)
    }

    @Test func imagePermissionChangesAndRequestDoNotRefreshAXOrRecapture() async {
        let probe = IconLifecycleProbe()
        let item = entry()
        let tray = probe.makeTray(entries: [item])
        defer { tray.close() }
        await tray.prepare(scope: .applications(["test.hidden"]))
        #expect(tray.entries.first?.icon === probe.image)

        probe.captureGranted = false
        tray.synchronizeIconPermission()
        #expect(!tray.screenCaptureAuthorized)
        #expect(tray.entries.map(\.id) == [item.id])
        #expect(tray.entries.first?.icon == nil)

        probe.captureGranted = true
        tray.synchronizeIconPermission()
        #expect(tray.screenCaptureAuthorized)
        #expect(tray.entries.first?.icon == nil)
        probe.captureGranted = false
        tray.synchronizeIconPermission()
        tray.requestOriginalIconsPermission()

        // 图片授权返回只更新权限；不能触发 organizer.onRefresh 导致整组展开，也不能重扫原 AX 入口。
        #expect(tray.screenCaptureAuthorized)
        #expect(tray.authorized)
        #expect(tray.entries.map(\.id) == [item.id])
        #expect(tray.entries.first?.icon == nil)
        #expect(probe.captureRequests == 1)
        #expect(probe.accessibilityRequests == 0)
        #expect(probe.refreshes == 0)
        #expect(probe.scans == 1)
        #expect(probe.capturedEntryIDs == [[item.id]])

        // 下次用户主动收纳才重新生成快照，证明授权同步没有提前取图。
        await tray.prepare(scope: .applications(["test.hidden"]))
        #expect(probe.scans == 2)
        #expect(probe.capturedEntryIDs == [[item.id], [item.id]])
        #expect(tray.entries.first?.icon === probe.image)
    }

    @Test func deniedRequestAfterExternalRevocationClearsCachedImageOnly() async {
        let probe = IconLifecycleProbe()
        let item = entry()
        let tray = probe.makeTray(entries: [item])
        defer { tray.close() }
        await tray.prepare(scope: .applications(["test.hidden"]))
        #expect(tray.entries.first?.icon === probe.image)

        // 外部刚撤权且还未轮询时，显式请求仍拒绝也必须撤回旧图片，不能被提前覆盖的权限值绕过。
        probe.captureGranted = false
        probe.permissionAfterRequest = false
        tray.requestOriginalIconsPermission()

        #expect(!tray.screenCaptureAuthorized)
        #expect(tray.authorized)
        #expect(tray.entries.map(\.id) == [item.id])
        #expect(tray.entries.first?.icon == nil)
        #expect(probe.captureRequests == 1)
        #expect(probe.accessibilityRequests == 0)
        #expect(probe.refreshes == 0)
        #expect(probe.scans == 1)
        #expect(probe.capturedEntryIDs == [[item.id]])
    }
}
