import AppKit
@preconcurrency import ApplicationServices
import ErmiCore

/// 三条扫描路径共享精确 AX 身份；屏幕坐标、标题和子节点下标都不能识别原入口。
/// 没有可靠跨启动标识的入口只保留本次进程内身份；重启后从新快照建立身份，绝不把旧顺序套到别的图标。
final class MenuBarEntryIdentity: @unchecked Sendable {
    static let shared = MenuBarEntryIdentity()
    private struct Record {
        let id: String
        let pid: pid_t
        let launchedAt: Date?
        let bundleID: String
        let element: AXUIElement
    }
    private let lock = NSLock()
    private var records: [Record] = []

    func id(pid: pid_t, bundleID: String, element: AXUIElement) -> String {
        let launchedAt = NSRunningApplication(processIdentifier: pid)?.launchDate
        lock.lock()
        defer { lock.unlock() }
        if let record = records.first(where: {
            $0.pid == pid && $0.launchedAt == launchedAt && $0.bundleID == bundleID && CFEqual($0.element, element)
        }) { return record.id }
        let id = "entry:" + UUID().uuidString
        records.append(Record(id: id, pid: pid, launchedAt: launchedAt, bundleID: bundleID, element: element))
        return id
    }

    func bundleID(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.id == id }?.bundleID
    }
}

enum MenuBarOrderResult: Sendable, Equatable {
    case success(moved: Int)
    case failure(String)
    case cancelled
}

@MainActor
struct MenuBarOrderAccess {
    var apply: ([String]) async -> MenuBarOrderResult

    static let system = MenuBarOrderAccess { await MenuBarOrdering.apply($0) }
}

// 规划使用本次读取的精确入口；旧版 App 顺序仅作为兼容入口，新拖动使用逐入口顺序。
// 分显示器建立目标，不把全局 x 排序误当成可以跨屏拖动的菜单栏。
struct MenuBarOrderPlan: Sendable {
    struct Position: Sendable, Equatable {
        let id: Int
        let bundleID: String
        let displayID: CGDirectDisplayID
        let frame: CGRect
        var entryID: String? = nil
    }

    struct Move: Sendable, Equatable {
        let source: Int
        let before: Int
    }

    let targetByDisplay: [CGDirectDisplayID: [Int]]

    init?(positions: [Position], entryIDs: [String]) {
        // 清单发生增删或身份重复时拒绝同步，不能按新下标补齐或忽略一个已失效入口。
        let actual = positions.compactMap(\.entryID)
        guard actual.count == positions.count, Set(actual).count == actual.count,
              Set(positions.map(\.id)).count == positions.count,
              Set(entryIDs).count == entryIDs.count, Set(actual) == Set(entryIDs) else { return nil }
        let ranks = Dictionary(uniqueKeysWithValues: entryIDs.enumerated().map { ($0.element, $0.offset) })
        targetByDisplay = Dictionary(grouping: positions, by: \.displayID).mapValues { entries in
            entries.sorted { ranks[$0.entryID!]! < ranks[$1.entryID!]! }.map(\.id)
        }
    }

    init?(positions: [Position], bundleIDs: [String]) {
        guard Set(positions.map(\.id)).count == positions.count else { return nil }
        var rank: [String: Int] = [:]
        for id in bundleIDs where rank[id] == nil { rank[id] = rank.count }
        guard positions.allSatisfy({ rank[$0.bundleID] != nil }) else { return nil }
        targetByDisplay = Dictionary(grouping: positions, by: \.displayID).mapValues { entries in
            let original = entries.sorted(by: Self.precedes)
            return original.enumerated().sorted {
                let lhs = rank[$0.element.bundleID]!
                let rhs = rank[$1.element.bundleID]!
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.map(\.element.id)
        }
    }

    func isSatisfied(by positions: [Position]) -> Bool {
        currentByDisplay(positions) == targetByDisplay
    }

    func nextMove(in positions: [Position]) -> Move? {
        let current = currentByDisplay(positions)
        // 身份集合或显示器变化时不能继续套用旧计划，也不能把缺项当成已经排好。
        guard current.keys.sorted() == targetByDisplay.keys.sorted() else { return nil }
        for display in targetByDisplay.keys.sorted() {
            guard let desired = targetByDisplay[display], let actual = current[display],
                  actual.count == desired.count, Set(actual) == Set(desired) else { return nil }
        }
        for display in targetByDisplay.keys.sorted() {
            guard let desired = targetByDisplay[display], let actual = current[display] else { return nil }
            for index in desired.indices where desired[index] != actual[index] {
                return Move(source: desired[index], before: actual[index])
            }
        }
        return nil
    }

    private func currentByDisplay(_ positions: [Position]) -> [CGDirectDisplayID: [Int]] {
        Dictionary(grouping: positions, by: \.displayID).mapValues {
            $0.sorted(by: Self.precedes).map(\.id)
        }
    }

    private static func precedes(_ lhs: Position, _ rhs: Position) -> Bool {
        lhs.frame.minX == rhs.frame.minX ? lhs.id < rhs.id : lhs.frame.minX < rhs.frame.minX
    }
}

@MainActor
private enum MenuBarOrdering {
    private struct Application: Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String
    }

    // AX 引用只在顺序后台任务中读取；不会按标题或刷新后的下标猜测原入口。
    private struct Entry: @unchecked Sendable {
        let id: Int
        let app: Application
        let element: AXUIElement
    }

    private struct Screen: Sendable, Equatable {
        let id: CGDirectDisplayID
        let bounds: CGRect
        let menuBarHeight: CGFloat
        let notch: CGRect?
    }

    private struct Failure: Error {
        let message: String
        let transientLayout: Bool
        init(_ message: String, transientLayout: Bool = false) {
            self.message = message
            self.transientLayout = transientLayout
        }
    }

    // 只在自身手势期间观察输入，不拦截用户事件；自身事件带唯一标记，真实输入会终止后续拖动。
    @MainActor
    private final class DragObservation {
        let marker = Int64.random(in: 1...Int64.max)
        private(set) var interrupted = false
        private(set) var receivedUp = false
        private var escapePressed = false
        private var globalMonitor: Any?
        private var localMonitor: Any?

        init() throws {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
                                               .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved,
                                               .flagsChanged, .keyDown]
            // 沿用展开栏的 AppKit 监听机制，不新增 Input Monitoring 授权或低层事件拦截。
            // keyDown 只检查 Esc 的 keyCode，不读取或保存输入内容，其余键盘事件直接忽略。
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                let type = event.type.rawValue
                let escape = event.type == .keyDown && event.keyCode == 53
                let source = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                MainActor.assumeIsolated { self?.receive(type: type, escape: escape, source: source) }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                // NSEvent 仍由当前回调持有并返回；跨 actor 只传 UInt / Bool / Int64? 快照。
                let type = event.type.rawValue
                let escape = event.type == .keyDown && event.keyCode == 53
                let source = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                MainActor.assumeIsolated { self?.receive(type: type, escape: escape, source: source) }
                return event
            }
            guard globalMonitor != nil, localMonitor != nil else {
                stop()
                throw Failure("无法监听排序期间的鼠标事件，未调整菜单栏顺序。")
            }
        }

        private func receive(type: UInt, escape: Bool, source: Int64?) {
            if type == NSEvent.EventType.keyDown.rawValue {
                if escape { escapePressed = true; interrupted = true }
                return
            }
            if source == marker {
                if type == NSEvent.EventType.leftMouseUp.rawValue { receivedUp = true }
            } else {
                interrupted = true
            }
        }

        func checkInterruption() throws {
            if escapePressed { throw CancellationError() }
            guard !interrupted else {
                throw Failure("检测到新的鼠标或键盘操作，已停止菜单栏排序，请稍后重试。")
            }
        }

        func stop() {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil
            localMonitor = nil
        }
    }

    private static var applying = false

    static func apply(_ requestedOrder: [String]) async -> MenuBarOrderResult {
        do {
            // 取消与新同步可能在不同 await 边界交错；旧拖动完成 mouseUp 清理前不能开始新拖动。
            let lockDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while applying {
                try Task.checkCancellation()
                guard ContinuousClock.now < lockDeadline else { throw Failure("上一次菜单栏排序尚未结束，请稍后重试。") }
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            applying = true
            defer { applying = false }
            try checkPermission()

            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownBundle = Bundle.main.bundleIdentifier
            var seen = Set<String>()
            let order = requestedOrder.filter { !$0.isEmpty && seen.insert($0).inserted }
            let perEntry = order.contains { $0.hasPrefix("entry:") }
            let bundleOrder = perEntry ? order.compactMap { MenuBarEntryIdentity.shared.bundleID(for: $0) } : order
            guard bundleOrder.count == order.count,
                  !bundleOrder.contains(where: { $0 == ownBundle || MenuBarVisibilityPlan.systemOwners.contains($0) }) else {
                throw Failure("菜单栏入口身份已失效，请刷新后重试。")
            }
            let running = NSWorkspace.shared.runningApplications
            let apps = Set(bundleOrder).sorted().flatMap { id in
                running.compactMap { app -> Application? in
                    guard app.processIdentifier != ownPID, !app.isTerminated, app.bundleIdentifier == id,
                          app.bundleURL?.pathExtension == "app" else { return nil }
                    return Application(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id)
                }
            }
            guard !order.isEmpty, Set(apps.map(\.bundleID)) == Set(bundleOrder) else {
                throw Failure("App 列表已变化，请刷新图标后重新同步菜单栏顺序。")
            }
            let screens = screenLayout()
            guard !screens.isEmpty else { throw Failure("无法读取当前显示器，未调整菜单栏顺序。") }
            let (entries, initial) = try await visibleSnapshot(apps: apps, screens: screens)
            // 公开 AX 可能只暴露活动屏幕的菜单栏；这里只核实当前这一栏，不宣称覆盖其他显示器的复制栏。
            guard Set(initial.map(\.displayID)).count == 1 else {
                throw Failure("目标图标分布在不同显示器，无法在当前菜单栏内安全同步顺序。")
            }
            guard let plan = perEntry ? MenuBarOrderPlan(positions: initial, entryIDs: order)
                : MenuBarOrderPlan(positions: initial, bundleIDs: order) else {
                throw Failure("菜单栏入口身份不明确，未调整顺序。")
            }
            // 初次检查所有入口，不能只验证将被拖动的一项而忽略隐藏或被刘海遮挡的其他项。
            try await verifyHits(entries, at: initial.map { ($0.id, CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
            var current = initial
            var moved = 0
            let operationDeadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !plan.isSatisfied(by: current) {
                try Task.checkCancellation()
                guard ContinuousClock.now < operationDeadline else {
                    throw Failure("菜单栏布局持续变化或排序超时，已停止同步，请检查后重试。")
                }
                try checkPermission()
                try checkApplications(apps)
                guard screenLayout() == screens else { throw Failure("显示器布局已变化，请重新同步菜单栏顺序。") }
                guard moved < entries.count, let move = plan.nextMove(in: current),
                      let source = current.first(where: { $0.id == move.source }),
                      let target = current.first(where: { $0.id == move.before }),
                      source.displayID == target.displayID else {
                    throw Failure("菜单栏布局在同步时发生变化，已停止排序；请刷新后重试。")
                }
                let idlePointer = try await waitForIdleInput()
                let observation = try DragObservation()
                defer { observation.stop() }
                let refreshed = try await positions(entries, screens: screens)
                guard refreshed == current else {
                    current = refreshed
                    continue
                }
                let start = CGPoint(x: source.frame.midX, y: source.frame.midY)
                // 落点位于目标左边缘内侧，既表达插入到它之前，也能用 AX 命中确认该目标。
                let end = CGPoint(x: target.frame.minX + min(1, target.frame.width / 4), y: target.frame.midY)
                try await verifyHits(entries, at: [(source.id, start), (target.id, end)])
                try checkPermission()
                try Task.checkCancellation()
                try await drag(from: start, to: end, expectedPointer: idlePointer, screens: screens, apps: apps, observation: observation)
                moved += 1

                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                var confirmed = false
                var transientFailure: Failure?
                repeat {
                    try Task.checkCancellation()
                    try checkPermission()
                    try checkApplications(apps)
                    // mouseUp 入队后系统还需完成布局；短暂重叠/越界不是成功，也不能立即当成最终失败。
                    try await Task.sleep(for: .milliseconds(40))
                    do {
                        current = try await positions(entries, screens: screens)
                        if let newSource = current.first(where: { $0.id == source.id }),
                           let newTarget = current.first(where: { $0.id == target.id }),
                           newSource.displayID == newTarget.displayID,
                           newSource.frame.maxX <= newTarget.frame.minX + 0.5 {
                            confirmed = true
                            break
                        }
                    } catch let error as Failure where error.transientLayout {
                        transientFailure = error
                        // 保留有限等待窗口；取消继续向上传播，不会被布局重试吞掉。
                    }
                } while ContinuousClock.now < deadline
                guard confirmed else {
                    if let transientFailure { throw transientFailure }
                    throw Failure("系统未确认菜单栏图标移动。部分位置可能已改变，请检查顶部菜单栏后重试。")
                }
            }
            // 发出事件不代表成功；停止移动后再次核对全部原入口，才能报告同步完成。
            try await Task.sleep(for: .milliseconds(60))
            try checkPermission()
            try checkApplications(apps)
            guard screenLayout() == screens else { throw Failure("显示器布局已变化，请重新同步菜单栏顺序。") }
            let final = try await positions(entries, screens: screens)
            guard plan.isSatisfied(by: final) else { throw Failure("菜单栏顺序未保持稳定，请检查顶部菜单栏后重试。") }
            try await verifyHits(entries, at: final.map { ($0.id, CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
            return .success(moved: moved)
        } catch is CancellationError {
            return .cancelled
        } catch let error as Failure {
            return .failure(error.message)
        } catch {
            return .failure("菜单栏排序失败，请检查顶部菜单栏后重试。")
        }
    }

    private static func checkPermission() throws {
        // 只检查现有授权；排序按钮不能在后台自动弹出授权，也不依赖录屏权限。
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw Failure("请先允许 Ermi 的辅助功能 / 设备控制和数据访问权限，再同步菜单栏顺序。")
        }
    }

    private static func checkApplications(_ apps: [Application]) throws {
        for app in apps {
            guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated,
                  running.bundleIdentifier == app.bundleID, running.bundleURL?.pathExtension == "app" else {
                throw Failure("App 已退出或重启，已停止菜单栏排序，请刷新后重试。")
            }
        }
    }

    private static func screenLayout() -> [Screen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(id)
            var notch: CGRect?
            if screen.safeAreaInsets.top > 0 {
                guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
                // AX/CG 使用全局左上原点；辅助区域是 AppKit 坐标，只需将其相对屏幕的水平区间映射过来。
                notch = CGRect(x: bounds.minX + left.maxX - screen.frame.minX, y: bounds.minY,
                               width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            }
            return Screen(id: id, bounds: bounds, menuBarHeight: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top), notch: notch)
        }.sorted { $0.id < $1.id }
    }

    private static func positions(_ entries: [Entry], screens: [Screen]) async throws -> [MenuBarOrderPlan.Position] {
        let frames = try await background { try readFrames(entries) }
        let result = try entries.map { entry -> MenuBarOrderPlan.Position in
            guard let frame = frames[entry.id], frame.width <= 512, frame.height <= 64 else {
                throw Failure("菜单栏入口尺寸异常，已停止排序。")
            }
            let matching = screens.filter { screen in
                screen.bounds.contains(frame)
                    && frame.minY >= screen.bounds.minY - 0.5
                    && frame.maxY <= screen.bounds.minY + screen.menuBarHeight + 2
                    && !(screen.notch?.intersects(frame) ?? false)
            }
            guard matching.count == 1, let screen = matching.first else {
                throw Failure("图标尚未完整显示、被刘海遮挡或跨越显示器边界，请先展开菜单栏再同步。", transientLayout: true)
            }
            return MenuBarOrderPlan.Position(id: entry.id, bundleID: entry.app.bundleID, displayID: screen.id, frame: frame,
                entryID: MenuBarEntryIdentity.shared.id(pid: entry.app.pid, bundleID: entry.app.bundleID, element: entry.element))
        }
        for group in Dictionary(grouping: result, by: \.displayID).values {
            let sorted = group.sorted { $0.frame.minX < $1.frame.minX }
            for pair in zip(sorted, sorted.dropFirst()) where pair.0.frame.maxX > pair.1.frame.minX + 0.5 {
                throw Failure("菜单栏入口位置重叠，无法准确排序，请刷新后重试。", transientLayout: true)
            }
        }
        return result
    }

    private static func visibleSnapshot(apps: [Application], screens: [Screen]) async throws -> ([Entry], [MenuBarOrderPlan.Position]) {
        // 上层先释放隐藏断言，原入口仍可能正在重新布局；在有限窗口内等待两次一致的真实快照。
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var previousEntries: [Entry] = []
        var previousPositions: [MenuBarOrderPlan.Position] = []
        var lastFailure: Failure?
        repeat {
            try Task.checkCancellation()
            try checkPermission()
            try checkApplications(apps)
            guard screenLayout() == screens else { throw Failure("显示器布局已变化，请重新同步菜单栏顺序。") }
            do {
                let entries = try await background { try scan(apps) }
                let current = try await positions(entries, screens: screens)
                if current == previousPositions, entries.count == previousEntries.count,
                   zip(entries, previousEntries).allSatisfy({ CFEqual($0.element, $1.element) }) {
                    return (entries, current)
                }
                previousEntries = entries
                previousPositions = current
            } catch let error as Failure {
                // 尚未建立原身份时可等待恢复；权限和 App 生命周期在 catch 外重新校验，绝不当动画吞掉。
                lastFailure = error
                previousEntries = []
                previousPositions = []
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw lastFailure ?? Failure("菜单栏恢复后仍在变化，请稍后重新同步顺序。")
    }

    private nonisolated static func scan(_ apps: [Application]) throws -> [Entry] {
        var result: [Entry] = []
        for app in apps {
            try Task.checkCancellation()
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var rawBar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &rawBar) == .success,
                  let rawBar, CFGetTypeID(rawBar) == AXUIElementGetTypeID() else {
                throw Failure("无法读取 \(app.name) 的菜单栏入口，请刷新后重试。")
            }
            let bar = unsafeDowncast(rawBar, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(bar, 0.15)
            var rawChildren: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &rawChildren) == .success,
                  let children = rawChildren as? [AXUIElement], !children.isEmpty else {
                throw Failure("\(app.name) 的菜单栏入口已变化，请刷新后重试。")
            }
            let items = MenuBarEntryFilter.managedItems(children, bundleID: app.bundleID)
            for child in items {
                try Task.checkCancellation()
                AXUIElementSetMessagingTimeout(child, 0.15)
                guard !result.contains(where: { CFEqual($0.element, child) }) else {
                    throw Failure("菜单栏入口身份重复，无法准确排序。")
                }
                var pid: pid_t = 0
                guard AXUIElementGetPid(child, &pid) == .success, pid == app.pid else {
                    throw Failure("\(app.name) 的菜单栏入口身份无法确认，未调整顺序。")
                }
                result.append(Entry(id: result.count, app: app, element: child))
            }
        }
        return result
    }

    private nonisolated static func readFrames(_ entries: [Entry]) throws -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        for entry in entries {
            try Task.checkCancellation()
            var pid: pid_t = 0
            var rawPosition: CFTypeRef?
            var rawSize: CFTypeRef?
            guard AXUIElementGetPid(entry.element, &pid) == .success, pid == entry.app.pid,
                  AXUIElementCopyAttributeValue(entry.element, kAXPositionAttribute as CFString, &rawPosition) == .success,
                  AXUIElementCopyAttributeValue(entry.element, kAXSizeAttribute as CFString, &rawSize) == .success,
                  let rawPosition, let rawSize, CFGetTypeID(rawPosition) == AXValueGetTypeID(),
                  CFGetTypeID(rawSize) == AXValueGetTypeID() else {
                throw Failure("\(entry.app.name) 的菜单栏入口已失效，已停止排序。")
            }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else {
                throw Failure("无法读取菜单栏图标的有效位置，已停止排序。")
            }
            result[entry.id] = CGRect(origin: point, size: size)
        }
        return result
    }

    private static func verifyHits(_ entries: [Entry], at points: [(Int, CGPoint)]) async throws {
        try await background {
            var seenPIDs = Set<pid_t>()
            let apps = entries.compactMap { entry in seenPIDs.insert(entry.app.pid).inserted ? entry.app : nil }
            let latest = try scan(apps)
            guard latest.count == entries.count,
                  entries.allSatisfy({ original in latest.contains { CFEqual(original.element, $0.element) } }) else {
                throw Failure("App 的菜单栏入口已增加、移除或重建，已停止排序，请刷新后重试。")
            }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.15)
            for (id, point) in points {
                try Task.checkCancellation()
                guard let entry = entries.first(where: { $0.id == id }) else { throw Failure("菜单栏入口身份已变化。") }
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                      let hit else { throw Failure("无法命中原菜单栏图标，请先确保它完整显示。") }
                var current = hit
                var matched = false
                // 图标内部可能还有 AXImage 子元素；只接受它本身或有限层父链上的精确原入口。
                for _ in 0..<6 {
                    if CFEqual(current, entry.element) { matched = true; break }
                    AXUIElementSetMessagingTimeout(current, 0.15)
                    var rawParent: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &rawParent) == .success,
                          let rawParent, CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { break }
                    current = unsafeDowncast(rawParent, to: AXUIElement.self)
                }
                guard matched else { throw Failure("原菜单栏图标被遮挡或无法准确命中，未继续排序。") }
            }
        }
    }

    private static func waitForIdleInput() async throws -> CGPoint {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var previous = CGEvent(source: nil)?.location
        repeat {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(80))
            let current = CGEvent(source: nil)?.location
            if inputIsReleased(), let current, current == previous { return current }
            previous = current
        } while ContinuousClock.now < deadline
        throw Failure("请先松开鼠标和修饰键，停止移动指针后再同步菜单栏顺序。")
    }

    private static func inputIsReleased() -> Bool {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift, .function])
        let buttonDown = [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }
        return modifiers.isEmpty && !buttonDown
    }

    private static func drag(from start: CGPoint, to end: CGPoint, expectedPointer: CGPoint,
                             screens: [Screen], apps: [Application], observation: DragObservation) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let initialPointer = CGEvent(source: nil)?.location,
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left),
              let fallbackUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: start, mouseButton: .left) else {
            throw Failure("无法创建菜单栏拖动事件，未调整顺序。")
        }
        down.flags = .maskCommand
        up.flags = []
        fallbackUp.flags = []
        for event in [down, up, fallbackUp] { event.setIntegerValueField(.eventSourceUserData, value: observation.marker) }
        var pressed = false
        var began = false
        defer {
            // 无论取消、撤权或创建中间事件失败，只要已按下就必须补发 mouseUp。
            // 这是结束手势的最佳努力清理；系统可能已移动部分入口，不声称能够回滚整个菜单栏。
            if pressed { fallbackUp.post(tap: .cghidEventTap) }
            // 用户已经接手鼠标或系统尚未确认 mouseUp 时，不再把指针强行拉回。
            if began, observation.receivedUp, !observation.interrupted, screenLayout() == screens {
                CGWarpMouseCursorPosition(initialPointer)
            }
        }
        try Task.checkCancellation()
        try observation.checkInterruption()
        // AX 校验包含 await；在真正按下前再次核实输入，不能沿用校验前的 idle 状态。
        guard inputIsReleased(), initialPointer == expectedPointer else {
            throw Failure("检测到新的鼠标或键盘操作，已停止菜单栏排序，请稍后重试。")
        }
        guard screenLayout() == screens else { throw Failure("显示器布局已变化，请重新同步菜单栏顺序。") }
        try checkApplications(apps)
        down.post(tap: .cghidEventTap)
        pressed = true
        began = true
        try await Task.sleep(for: .milliseconds(30))
        for step in 1...8 {
            try Task.checkCancellation()
            try checkPermission()
            try checkApplications(apps)
            guard screenLayout() == screens else { throw Failure("显示器布局已变化，请重新同步菜单栏顺序。") }
            try observation.checkInterruption()
            let fraction = CGFloat(step) / 8
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else {
                throw Failure("菜单栏拖动事件创建失败，已停止排序。")
            }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: observation.marker)
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(15))
        }
        try Task.checkCancellation()
        try observation.checkInterruption()
        up.post(tap: .cghidEventTap)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        while !observation.receivedUp {
            try Task.checkCancellation()
            try observation.checkInterruption()
            guard ContinuousClock.now < deadline else { throw Failure("系统未确认拖动结束，已补发释放事件，请检查菜单栏。") }
            try await Task.sleep(for: .milliseconds(10))
        }
        pressed = false
        // 回执只证明 AppKit 观察到了释放事件；最终是否移动成功仍由外层重读 AX 位置决定。
        try await Task.sleep(for: .milliseconds(30))
    }

    private nonisolated static func background<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) { try operation() }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }
}
