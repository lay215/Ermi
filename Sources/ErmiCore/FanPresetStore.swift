import Foundation

public enum FanPresetStoreError: Error, LocalizedError {
    case invalidDocument
    case duplicateName
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "预设文件无效，原文件已保留。请先备份并修复后再保存。"
        case .duplicateName: return "已有同名方案，请使用其他名称；原方案未被覆盖。"
        }
    }
}

/// 持久化只读写预设，不引用设备或控制器，因此保存及启动加载均不会应用硬件设置。
public actor FanPresetStore {
    private struct Document: Codable { let version: Int; let presets: [FanPreset] }
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> [FanPreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decode(Data(contentsOf: url))
    }
    public func save(_ presets: [FanPreset]) throws {
        // 每次保存前重新验证现存文件，避免坏文件或并发外部编辑被空列表覆盖。
        if FileManager.default.fileExists(atPath: url.path) { _ = try decode(Data(contentsOf: url)) }
        try validate(presets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, presets: presets))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    /// 读取与更新在同一 actor 操作内完成，编辑只匹配 ID，同名冲突不能静默覆盖其他方案。
    public func upsert(_ preset: FanPreset) throws -> [FanPreset] {
        var current = try load()
        guard !current.contains(where: { $0.id != preset.id && $0.name == preset.name }) else {
            throw FanPresetStoreError.duplicateName
        }
        if let index = current.firstIndex(where: { $0.id == preset.id }) { current[index] = preset }
        else { current.append(preset) }
        try save(current)
        return current
    }
    /// 按稳定 ID 删除已保存方案，不触及控制器；先读最新文件，保留其他方案及其顺序。
    public func remove(id: UUID) throws -> [FanPreset] {
        let current = try load()
        let remaining = current.filter { $0.id != id }
        if remaining.count != current.count { try save(remaining) }
        return remaining
    }
    private func decode(_ data: Data) throws -> [FanPreset] {
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw FanPresetStoreError.invalidDocument }
            try validate(document.presets)
            return document.presets
        } catch { throw FanPresetStoreError.invalidDocument }
    }
    private func validate(_ presets: [FanPreset]) throws {
        guard Set(presets.map(\.id)).count == presets.count,
              presets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && valid($0.configuration) }) else { throw FanPresetStoreError.invalidDocument }
    }
    private func valid(_ configuration: FanControlConfiguration) -> Bool {
        // 持久化可独立判断参数结构，硬件min/max仍由应用当时的设备能力校验。
        switch configuration {
        case .fixed(let rpm): return rpm.isFinite && rpm >= 0
        case .fixedTargets(let targets):
            return !targets.isEmpty && Set(targets.map(\.index)).count == targets.count
                && targets.allSatisfy { $0.index >= 0 && $0.rpm.isFinite && $0.rpm >= 0 }
        case .thermal(let rule):
            // 与控制器共用来源和键组合校验；旧来源只接受无键，新来源必须有合法温度键。
            return rule.hasValidSensorSelection && rule.lowerTemperature.isFinite && rule.upperTemperature.isFinite
                && rule.lowerTemperature >= 0 && rule.upperTemperature <= 150 && rule.upperTemperature > rule.lowerTemperature
                && (rule.lowerRPM.map { $0.isFinite && $0 >= 0 } ?? true)
                && (rule.upperRPM.map { $0.isFinite && $0 >= 0 } ?? true)
                && (rule.lowerRPM == nil || rule.upperRPM == nil || rule.lowerRPM! <= rule.upperRPM!)
                && (rule.rampRPMPerSecond.map { $0.isFinite && $0 > 0 } ?? true)
        }
    }
}
