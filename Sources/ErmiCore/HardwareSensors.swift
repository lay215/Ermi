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

// 当前只确认 M1 Max 的温度映射，不把同名 T* key 泛化到未验证芯片。
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
        // Stats 的 M1Gen 映射分别列出效率核、性能核及GPU，不枚举未知传感器后按名字猜测。
        let supported = cpuBrand == "Apple M1 Max" && ["MacBookPro18,2", "MacBookPro18,4"].contains(model)
        let cpu = supported ? temperature(keys: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]) : nil
        let gpu = supported ? temperature(keys: ["Tg05", "Tg0D", "Tg0L", "Tg0T"]) : nil
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

    private func temperature(keys: [String]) -> TemperatureReading? {
        let readings: [(String, Double)] = keys.compactMap { key in
            guard let value = try? transport.read(key).number, value > 0, value <= 150 else { return nil }
            return (key, value)
        }
        guard !readings.isEmpty else { return nil }
        // 显示本轮可用核心传感器的算术均值；记录参与key，缺失时不会混入0或旧值。
        return TemperatureReading(celsius: readings.map(\.1).reduce(0, +) / Double(readings.count), sensorKeys: readings.map(\.0), aggregation: "mean of available core sensors")
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
