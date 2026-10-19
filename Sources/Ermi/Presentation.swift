import Foundation
import ErmiCore

enum DetailPage: String { case monitor, presets, icons, settings }
enum FanMode: Int, CaseIterable {
    case system, auto, fixed
    var label: String { switch self { case .system: "系统自动"; case .auto: "App 自动"; case .fixed: "固定 RPM" } }
}

struct DisplayProcess: Identifiable {
    let id: String
    let name: String
    let memory: String
    let cpu: String
    let source: ProcessSample?
    let memoryValue: Double
    let cpuValue: Double
}

// 固定数据只供显式 --design-reference 截图诊断使用，不进入真实采样和进程操作。
enum R4Fixture {
    static let processes: [DisplayProcess] = [
        ("飞书", 57.7, 2.61), ("TraceCode CN", 33.7, 6.45), ("微信", 22.9, 2.23), ("ChatGPT", 9.1, 3.46), ("Google Chrome", 2.8, 6.02)
    ].map { name, cpu, memory in DisplayProcess(id: name, name: name, memory: String(format: "%.2f GiB", memory), cpu: String(format: "%.1f", cpu), source: nil, memoryValue: memory, cpuValue: cpu) }
    static let memory = [30.0,29,30,27,28,25,26,24,25,20,21,20,22,20,18,20,17,18,15,17,16].map { (43 - $0) / 43 * 100 }
    static let cpu = [59.0,54,57,40,44,36,48,19,26,45,34,39,25,36,29,35,25,38,32,40,31,36,28,38,34].map { (74 - $0) / 74 * 100 }
    static let gpu = [65.0,65,65,63,65,62.5,60,62,62,62,62,56,58,58.5,59,44,44,44,44,60,59.5,59,60,61,62].map { (74 - $0) / 74 * 100 }
}

extension MonitorModel {
    private var allDisplayProcesses: [DisplayProcess] {
        if designPreview { return R4Fixture.processes }
        return (snapshot?.processes ?? []).map { p in
            DisplayProcess(id: "\(p.id.pid):\(p.id.startSeconds):\(p.id.startMicroseconds)", name: p.name,
                           memory: String(format: "%.2f GiB", Double(p.memoryBytes) / 1_073_741_824),
                           cpu: p.cpuPercent.map { String(format: "%.1f", $0) } ?? "—", source: p,
                           memoryValue: Double(p.memoryBytes), cpuValue: p.cpuPercent ?? -1)
        }
    }
    var displayProcesses: [DisplayProcess] { sortedDisplays(memory: sortByMemory) }
    var detailProcesses: [DisplayProcess] { sortedDisplays(memory: detailSortByMemory) }
    private func sortedDisplays(memory: Bool) -> [DisplayProcess] {
        allDisplayProcesses.sorted {
            let lhs = memory ? $0.memoryValue : $0.cpuValue
            let rhs = memory ? $1.memoryValue : $1.cpuValue
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }
    var cpuHistory: [Double] { designPreview ? R4Fixture.cpu : (snapshot?.history.compactMap(\.cpuPercent) ?? []) }
    var gpuHistory: [Double] { designPreview ? R4Fixture.gpu : [] }
    var memoryHistory: [Double] { designPreview ? R4Fixture.memory : (snapshot?.history.compactMap(\.memoryPercent) ?? []) }
    var memoryGB: String { designPreview ? "37.7" : snapshot?.memory.map { String(format: "%.1f", Double($0.usedBytes) / 1_073_741_824) } ?? "—" }
    var totalMemoryGB: String { designPreview ? "64" : snapshot?.memory.map { String(format: "%.0f", Double($0.totalBytes) / 1_073_741_824) } ?? "—" }
    var memoryPercentText: String { designPreview ? "59" : snapshot?.memory.map { String(format: "%.0f", $0.usedPercent) } ?? "—" }
    var cpuText: String { designPreview ? "32" : snapshot?.cpuPercent.map { String(format: "%.0f", $0) } ?? "—" }
    var thermalText: String {
        if designPreview { return "热状态正常" }
        switch snapshot?.thermalState {
        case .nominal: return "热状态正常"
        case .fair: return "热状态略高"
        case .serious: return "热状态较高"
        case .critical: return "热状态严重"
        default: return "热状态待读取"
        }
    }
}

extension MonitorModel {
    var cpuTemperatureText: String {
        if designPreview { return "62" }
        return snapshot?.hardware.cpuTemperature.map { String(format: "%.0f", $0.celsius) } ?? "—"
    }
    var gpuTemperatureText: String {
        if designPreview { return "58" }
        return snapshot?.hardware.gpuTemperature.map { String(format: "%.0f", $0.celsius) } ?? "—"
    }
    var cpuTemperatureCaption: String {
        if designPreview { return "CPU 温度 · 示例" }
        if snapshot == nil { return "CPU 温度 · 正在读取" }
        return snapshot?.hardware.cpuTemperature == nil ? "CPU 温度 · 暂不可用" : "CPU 温度 · 可用传感器"
    }
    var temperatureHelp: String {
        guard !designPreview, let reading = snapshot?.hardware.cpuTemperature else { return "温度来源：AppleSMC" }
        return String(format: L("CPU 温度 %.1f°C · %d 个可用传感器\nAppleSMC: %@"), reading.celsius, reading.sensorKeys.count, reading.sensorKeys.joined(separator: ", "))
    }
    var hasFanReadings: Bool { designPreview || snapshot?.hardware.fans.contains(where: { $0.rpm != nil }) == true }
    // 读数与控制能力均按真实索引展示，不为单风扇或无风扇机器虚构第二只风扇。
    var displayedFanIndices: [Int] {
        if designPreview { return [0, 1] }
        return Set((snapshot?.hardware.fans.map(\.index) ?? []) + fanCapabilities.map(\.index)).sorted()
    }
    var fanRPMText: String {
        let values = displayedFanIndices.map { fanRPM($0) }
        return values.isEmpty ? "— RPM" : values.joined(separator: " / ") + " RPM"
    }
    func fanLabel(_ index: Int) -> String {
        if designPreview { return index == 0 ? "左" : "右" }
        // 实际描述为空时按设备编号展示；不从 F0/F1 推断物理左右位置。
        return snapshot?.hardware.fans.first(where: { $0.index == index })?.name ?? "风扇 \(index + 1)"
    }
    func fanRPM(_ index: Int) -> String {
        if designPreview { return index == 0 ? "2,840" : "2,760" }
        guard let value = snapshot?.hardware.fans.first(where: { $0.index == index })?.rpm else { return "—" }
        return Int(value.rounded()).formatted()
    }
    func fanHelp(_ index: Int) -> String {
        guard let fan = snapshot?.hardware.fans.first(where: { $0.index == index }) else { return "风扇读数暂不可用" }
        return "\(fan.name) · AppleSMC \(fan.sourceKey) · 实测 RPM"
    }
}

import AppKit
import SwiftUI
import Darwin

/// 进程列表按真实可执行路径找所属 App；命令行进程使用通用图标，不伪造首字母标识。
@MainActor
struct ProcessAppIcon: View {
    let process: DisplayProcess
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: ProcessIconResolver.image(for: process)).resizable().interpolation(.high)
            .scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

@MainActor
final class ProcessIconCache {
    private struct Key: Hashable {
        let identity: ProcessIdentity
        let name: String
    }
    private struct Entry {
        let image: NSImage
        let resolvedAt: TimeInterval
    }
    private var entries: [Key: Entry] = [:]
    private let capacity: Int
    private let lifetime: TimeInterval

    init(capacity: Int = 256, lifetime: TimeInterval = 5) {
        self.capacity = max(1, capacity)
        self.lifetime = lifetime
    }

    func image(identity: ProcessIdentity, name: String, now: TimeInterval, resolve: () -> NSImage) -> NSImage {
        // 身份来自 PROC_PIDTBSDINFO 的 PID 和启动时间，不能仅用 PID，以免复用后串图标。
        // 名称变化立即重查；短期缓存也会过期，允许 exec 或 App 延迟注册后的路径重新解析。
        let key = Key(identity: identity, name: name)
        if let entry = entries[key], now >= entry.resolvedAt, now - entry.resolvedAt < lifetime {
            return entry.image
        }
        let image = resolve()
        entries.removeValue(forKey: key)
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.resolvedAt < $1.value.resolvedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        // 通用图标也缓存，避免命令行进程每次动画重绘都再次调用进程查询。
        entries[key] = Entry(image: image, resolvedAt: now)
        return image
    }
}

@MainActor
private enum ProcessIconResolver {
    private static let cache = NSCache<NSString, NSImage>()
    private static let processCache = ProcessIconCache()
    static func image(for process: DisplayProcess) -> NSImage {
        guard let source = process.source else { return resolveImage(for: process) }
        return processCache.image(identity: source.id, name: process.name, now: ProcessInfo.processInfo.systemUptime) {
            resolveImage(for: process)
        }
    }

    private static func resolveImage(for process: DisplayProcess) -> NSImage {
        if let source = process.source {
            if let app = NSRunningApplication(processIdentifier: source.pid), let url = app.bundleURL {
                return icon(at: url)
            }
            // Helper 不一定注册为 NSRunningApplication，从执行路径向外找到最外层 App。
            // 身份缓存未命中时重新解析路径；图片资源仍按 bundle 路径共享。
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(source.pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let components = URL(fileURLWithPath: path).pathComponents
                if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
                    return icon(at: URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(index + 1)))))
                }
            }
        } else {
            // 仅设计诊断数据按已知 bundle ID 查安装图标；绝不据展示名称发起进程操作。
            let ids = ["飞书": "com.electron.lark", "微信": "com.tencent.xinWeChat", "ChatGPT": "com.openai.chat", "Google Chrome": "com.google.Chrome"]
            if let id = ids[process.name], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return icon(at: url) }
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "应用")!
    }
    private static func icon(at url: URL) -> NSImage {
        let key = url.path as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.countLimit = 128
        cache.setObject(image, forKey: key)
        return image
    }
}

extension MonitorModel {
    // 容量标签明确区分十进制磁盘 GB 与二进制内存 GiB，不混用统计口径。
    var diskAvailableText: String { snapshot?.disk.map { String(format: "%.0f", Double($0.availableBytes) / 1_000_000_000) } ?? "—" }
    var diskDetailText: String {
        guard let disk = snapshot?.disk else { return "空间暂不可用" }
        return String(format: L("共 %.0f GB · 已用 %.0f%%"), Double(disk.totalBytes) / 1_000_000_000, disk.totalBytes > 0 ? Double(disk.usedBytes) / Double(disk.totalBytes) * 100 : 0)
    }
    var diskHelp: String { snapshot?.disk.map { "用户目录所在卷：\($0.volumeName)；GB 为十进制容量，可用量不含估算的可清除空间。" } ?? "正在读取用户目录所在卷" }
    var batteryText: String {
        guard let battery = snapshot?.battery else { return "—" }
        guard battery.isPresent else { return "无电池" }
        return battery.chargePercent.map { String(format: "%.0f%%", $0) } ?? "—"
    }
    var batteryDetailText: String {
        guard let battery = snapshot?.battery else { return "电源信息暂不可用" }
        guard battery.isPresent else { return "台式设备 / 无内置电池" }
        if battery.isCharging == true { return "正在充电" }
        if battery.isExternalPower == true { return (battery.chargePercent ?? 0) >= 100 ? "已充满 · 电源接通" : "电源接通 · 未充电" }
        if battery.isExternalPower == false { return "电池供电" }
        return "电源状态未知"
    }
    var memoryPressureText: String {
        if designPreview { return "压力正常" }
        switch snapshot?.memoryPressure {
        case .normal: return "压力正常"
        case .warning: return "压力偏高"
        case .critical: return "压力很高"
        case nil: return "压力未知"
        }
    }
    var networkText: String {
        guard let network = snapshot?.network else { return "网络暂不可用" }
        return "↓ \(networkRate(network.receivedBytesPerSecond)) · ↑ \(networkRate(network.sentBytesPerSecond))"
    }
    var networkHelp: String {
        guard let network = snapshot?.network else { return "未读取到活动物理网络接口" }
        return "物理接口 \(network.interfaceNames.joined(separator: ", ")) 的总流量，不重复统计 VPN；连接切换或首帧等待下次采样。"
    }
    var uptimeText: String {
        guard let boot = snapshot?.bootTime, let now = snapshot?.timestamp else { return "运行时间未知" }
        let minutes = max(0, Int(now.timeIntervalSince(boot) / 60))
        return minutes >= 1440 ? "运行 \(minutes / 1440) 天" : minutes >= 60 ? "运行 \(minutes / 60) 小时" : "运行 \(minutes) 分钟"
    }
    private func networkRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }
}
