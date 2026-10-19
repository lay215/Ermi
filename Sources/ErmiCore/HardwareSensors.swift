import Foundation
import Darwin

public struct TemperatureReading: Sendable, Codable {
    public let celsius: Double
    public let sensorKeys: [String]
    public let aggregation: String
}

public struct FanReading: Identifiable, Sendable, Codable {
    public let index: Int
    public let name: String
    public let rpm: Double?
    public let sourceKey: String
    public var id: Int { index }
}

public struct HardwareSnapshot: Sendable, Codable {
    public let deviceModel: String
    public let cpuTemperature: TemperatureReading?
    public let gpuTemperature: TemperatureReading?
    public let fans: [FanReading]
    public let source: String
}

// 按芯片族选择有上游依据的温度语义；机型和风扇数量不决定温度映射。
final class HardwareSensorReader {
    private let transport: any SMCKeyReading
    private let model: String
    private let cpuBrand: String
    init(transport: any SMCKeyReading = SMCReadOnlyTransport(), model: String? = nil, cpuBrand: String? = nil) {
        self.transport = transport
        self.model = model ?? Self.sysctlString("hw.model")
        self.cpuBrand = cpuBrand ?? Self.sysctlString("machdep.cpu.brand_string")
    }

    func sample() -> HardwareSnapshot {
        let profile = Self.temperatureProfile(cpuBrand: cpuBrand)
        // Intel 优先核心均值；仅核心全缺失才使用 package/diode，散热片与邻近温度不冒充芯片温度。
        let cpu = profile.flatMap { profile in
            temperature(keys: profile.cpu) ?? profile.cpuFallback.lazy.compactMap { key in
                self.temperature(keys: [key], aggregation: "CPU package/diode sensor")
            }.first
        }
        let gpu = profile.flatMap { temperature(keys: $0.gpu, aggregation: $0.gpuAggregation, useMaximum: $0.gpuMaximum) }
        var fans: [FanReading] = []
        if let count = try? transport.read("FNum").number, count.rounded() == count, (0...10).contains(count) {
            for index in 0..<Int(count) {
                let key = "F\(index)Ac"
                let measured = try? transport.read(key).number
                // 零RPM是有效的停转读数，不能等同传感器缺失；不读目标转速替代实测。
                let rpm = measured.flatMap { (0...30_000).contains($0) ? $0 : nil }
                let name = (try? transport.read("F\(index)ID").fanName) ?? "风扇 \(index + 1)"
                fans.append(FanReading(index: index, name: name, rpm: rpm, sourceKey: key))
            }
        }
        return HardwareSnapshot(deviceModel: model, cpuTemperature: cpu, gpuTemperature: gpu, fans: fans, source: "AppleSMC · read-only")
    }

    private func temperature(keys: [String], aggregation: String = "mean of available core sensors", useMaximum: Bool = false) -> TemperatureReading? {
        let readings: [(String, Double)] = keys.compactMap { key in
            guard let value = try? transport.read(key).number, value > 0, value <= 150 else { return nil }
            return (key, value)
        }
        guard !readings.isEmpty else { return nil }
        // 显示本轮可用核心传感器的算术均值；记录参与key，缺失时不会混入0或旧值。
        // Intel 可能同时暴露同一 GPU 的 Radeon/diode 与集显；取最大值避免重复加权，并保守反映最热 GPU。
        let celsius = useMaximum ? readings.map(\.1).max()! : readings.map(\.1).reduce(0, +) / Double(readings.count)
        return TemperatureReading(celsius: celsius, sensorKeys: readings.map(\.0), aggregation: aggregation)
    }

    private struct TemperatureProfile {
        let cpu: [String]
        let gpu: [String]
        var cpuFallback: [String] = []
        var gpuAggregation: String = "mean of available core sensors"
        var gpuMaximum = false
    }

    private static func temperatureProfile(cpuBrand: String) -> TemperatureProfile? {
        // 来源与平台集合固定在 docs/research/temperature-compatibility.md；未知后缀/未来芯片不复用相似 key。
        switch cpuBrand.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Apple M1", "Apple M1 Pro", "Apple M1 Max", "Apple M1 Ultra":
            return TemperatureProfile(cpu: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
                                      gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        case "Apple M2", "Apple M2 Pro", "Apple M2 Max", "Apple M2 Ultra":
            return TemperatureProfile(cpu: ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
                                      gpu: ["Tg0f", "Tg0j"])
        case "Apple M3", "Apple M3 Pro", "Apple M3 Max", "Apple M3 Ultra":
            return TemperatureProfile(cpu: ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                                      gpu: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
        case "Apple M4":
            return TemperatureProfile(cpu: ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
                                      gpu: ["Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        case "Apple M4 Pro", "Apple M4 Max":
            return TemperatureProfile(cpu: ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
                                      gpu: ["Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        case "Apple M5", "Apple M5 Pro", "Apple M5 Max", "Apple M5 Ultra":
            return TemperatureProfile(cpu: ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
                                      gpu: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"])
        case "Apple M6", "Apple M6 Pro", "Apple M6 Max":
            return TemperatureProfile(cpu: ["Tp0j", "Tp0g", "Tp09", "Tp07", "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05", "Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"],
                                      gpu: ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"])
        case "Apple A18 Pro":
            return TemperatureProfile(cpu: ["Te05", "Te0S", "Tp05", "Tp0D"], gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0e"])
        case let brand where brand.hasPrefix("Intel"):
            // Stats 的 TC%c/TC%C 模板明确展开 0..<10；TCAC/TCBC 同属其 average 集合，表示传感器均值而非物理核心一一对应。
            let cores = ["TCAC", "TCBC"] + (0..<10).map { "TC\($0)c" } + (0..<10).map { "TC\($0)C" }
            return TemperatureProfile(cpu: cores, gpu: ["TCGC", "TG0D", "TGDD"],
                                      cpuFallback: ["TCAD", "TC0D", "TC0E", "TC0F"],
                                      gpuAggregation: "maximum of available GPU die sensors", gpuMaximum: true)
        default:
            return nil
        }
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
