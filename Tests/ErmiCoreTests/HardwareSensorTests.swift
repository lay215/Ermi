import Foundation
import Testing
@testable import ErmiCore

private final class SensorFixture: SMCKeyReading {
    var values: [String: SMCValue] = [:]
    var requested: [String] = []
    func read(_ key: String) throws -> SMCValue {
        requested.append(key)
        guard let value = values[key] else { throw SMCReadError.missingKey }
        return value
    }
    func set(_ key: String, _ value: Float) {
        let bits = value.bitPattern
        values[key] = SMCValue(key: key, type: "flt ", bytes: (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) })
    }
}

struct HardwareSensorTests {
    @Test func decodesWireValuesAndRejectsMalformedData() {
        #expect(SMCValue(key: "test", type: "flt ", bytes: [0, 0, 0x7c, 0x42]).number == 63)
        #expect(SMCValue(key: "test", type: "fpe2", bytes: [0x24, 0x58]).number == 2326)
        #expect(SMCValue(key: "test", type: "ui16", bytes: [0x01, 0x02]).number == 258)
        #expect(SMCValue(key: "test", type: "ui32", bytes: [0, 1, 0, 2]).number == 65538)
        #expect(SMCValue(key: "test", type: "sp78", bytes: [0xff, 0x80]).number == -0.5)
        #expect(SMCValue(key: "test", type: "flt ", bytes: [0, 0]).number == nil)
        #expect(SMCValue(key: "test", type: "flt ", bytes: [0, 0, 0x80, 0x7f]).number == nil)
        #expect(SMCValue(key: "test", type: "xxxx", bytes: [1]).number == nil)
    }

    @Test func computesMappedCoreMeanWithoutTreatingMissingSensorsAsZero() throws {
        let fixture = SensorFixture()
        fixture.set("Tp09", 40); fixture.set("Tp01", 80); fixture.set("Tg05", 50)
        fixture.set("Tp0T", 0); fixture.set("Tp05", 200)
        fixture.set("Txyz", 120)
        let reader = HardwareSensorReader(transport: fixture, model: "MacBookPro18,4", cpuBrand: "Apple M1 Max")
        let sample = reader.sample()
        let cpu = try #require(sample.cpuTemperature)
        #expect(cpu.celsius == 60)
        #expect(cpu.sensorKeys == ["Tp09", "Tp01"])
        #expect(sample.gpuTemperature?.celsius == 50)
        #expect(!fixture.requested.contains("Txyz"))
        fixture.values.removeAll()
        #expect(reader.sample().cpuTemperature == nil)
    }

    @Test func preservesZeroRPMAndAvoidsInferringPhysicalPosition() throws {
        let fixture = SensorFixture()
        fixture.values["FNum"] = SMCValue(key: "FNum", type: "ui8 ", bytes: [2])
        fixture.set("F0Ac", 0); fixture.set("F1Ac", 2500)
        fixture.set("F0Tg", 5000)
        fixture.values["F1ID"] = SMCValue(key: "F1ID", type: "{fds", bytes: [0, 0, 0, 0] + Array("Right".utf8) + [UInt8](repeating: 0, count: 7))
        let sample = HardwareSensorReader(transport: fixture, model: "MacBookPro18,4", cpuBrand: "Apple M1 Max").sample()
        #expect(sample.fans.count == 2)
        #expect(sample.fans[0].rpm == 0)
        #expect(sample.fans[0].name == "风扇 1")
        #expect(sample.fans[1].rpm == 2500)
        #expect(sample.fans[1].name == "Right")
        #expect(sample.fans[0].sourceKey == "F0Ac")
        #expect(!fixture.requested.contains("F0Tg"))
    }

    @Test func invalidOrAbsentFanValuesDoNotBecomeZero() {
        let fixture = SensorFixture()
        fixture.values["FNum"] = SMCValue(key: "FNum", type: "ui8 ", bytes: [2])
        fixture.set("F0Ac", -10)
        let sample = HardwareSensorReader(transport: fixture, model: "MacBookPro18,4", cpuBrand: "Apple M1 Max").sample()
        #expect(sample.fans.count == 2)
        #expect(sample.fans.allSatisfy { $0.rpm == nil })
        fixture.values["FNum"] = SMCValue(key: "FNum", type: "ui8 ", bytes: [255])
        #expect(HardwareSensorReader(transport: fixture).sample().fans.isEmpty)
    }

    @Test func unknownDeviceDoesNotReuseM1MaxTemperatureMapping() {
        let fixture = SensorFixture(); fixture.set("Tp09", 65)
        let sample = HardwareSensorReader(transport: fixture, model: "FutureMac1,1", cpuBrand: "Apple M9").sample()
        #expect(sample.cpuTemperature == nil)
        #expect(sample.gpuTemperature == nil)
        #expect(fixture.requested == ["FNum"])
    }

    @Test(arguments: [
        ("Apple M1", "Tp09", "Tg05"), ("Apple M1 Pro", "Tp0b", "Tg0T"),
        ("Apple M1 Ultra", "Tp01", "Tg0D"), ("Apple M2", "Tp1h", "Tg0f"),
        ("Apple M2 Pro", "Tp1t", "Tg0j"), ("Apple M2 Max", "Tp0f", "Tg0f"),
        ("Apple M2 Ultra", "Tp0j", "Tg0j"), ("Apple M3", "Te05", "Tf14"),
        ("Apple M3 Pro", "Tf04", "Tf18"), ("Apple M3 Max", "Tf4E", "Tf2A"),
        ("Apple M3 Ultra", "Tf49", "Tf29"), ("Apple M4", "Te09", "Tg0G"),
        ("Apple M4 Pro", "Tp0V", "Tg1U"), ("Apple M4 Max", "Tp0e", "Tg1k"),
        ("Apple M5", "Tp00", "Tg0U"), ("Apple M5 Pro", "Tp0O", "Tg0X"),
        ("Apple M5 Max", "Tp0y", "Tg1g"), ("Apple M5 Ultra", "Tp0u", "Tg1c"),
        ("Apple M6", "Tp0j", "Tg1e"), ("Apple M6 Pro", "Te0i", "Tg1h"),
        ("Apple M6 Max", "Tp0I", "Tg0c"), ("Apple A18 Pro", "Te0S", "Tg0e")
    ])
    func readsDocumentedChipFamiliesWithoutChassisWhitelist(brand: String, cpuKey: String, gpuKey: String) {
        let fixture = SensorFixture()
        fixture.set(cpuKey, 60); fixture.set(gpuKey, 50)
        let sample = HardwareSensorReader(transport: fixture, model: "DifferentChassis", cpuBrand: brand).sample()
        #expect(sample.cpuTemperature?.celsius == 60)
        #expect(sample.gpuTemperature?.celsius == 50)
        #expect(sample.fans.isEmpty)
    }

    @Test func m4GPUVariantDoesNotReadOtherVariantsSensors() {
        let fixture = SensorFixture()
        fixture.set("Tg0G", 40); fixture.set("Tg1U", 80)
        #expect(HardwareSensorReader(transport: fixture, model: "Mac16,10", cpuBrand: "Apple M4").sample().gpuTemperature?.celsius == 40)
        #expect(!fixture.requested.contains("Tg1U"))
        fixture.requested.removeAll()
        #expect(HardwareSensorReader(transport: fixture, model: "Mac16,11", cpuBrand: "Apple M4 Pro").sample().gpuTemperature?.celsius == 80)
        #expect(!fixture.requested.contains("Tg0G"))
    }

    @Test func intelCoreMeanPrecedesPackageAndNeverUsesProximity() {
        let fixture = SensorFixture()
        fixture.set("TC0c", 40); fixture.set("TC1C", 80); fixture.set("TCAD", 100)
        fixture.set("TC0P", 20); fixture.set("TC0H", 30); fixture.set("TG0D", 70)
        fixture.set("TGDD", 70); fixture.set("TCGC", 40)
        let reader = HardwareSensorReader(transport: fixture, model: "iMac19,1", cpuBrand: "Intel(R) Core(TM) i9")
        #expect(reader.sample().cpuTemperature?.celsius == 60)
        #expect(reader.sample().gpuTemperature?.celsius == 70)
        fixture.values.removeValue(forKey: "TC0c"); fixture.values.removeValue(forKey: "TC1C")
        #expect(reader.sample().cpuTemperature?.sensorKeys == ["TCAD"])
        fixture.values.removeValue(forKey: "TCAD")
        #expect(reader.sample().cpuTemperature == nil)
        #expect(!fixture.requested.contains("TC0P"))
        #expect(!fixture.requested.contains("TC0H"))
    }

    @Test(arguments: ["", "Apple M9", "Apple M4 Ultra", "Apple M6 Ultra", "Apple M1 Max Unknown"])
    func unknownBrandNeverProbesKnownTemperatureMappings(brand: String) {
        let fixture = SensorFixture()
        fixture.set("Tp09", 65); fixture.set("TCAD", 65)
        let sample = HardwareSensorReader(transport: fixture, model: "MacBookPro18,4", cpuBrand: brand).sample()
        #expect(sample.cpuTemperature == nil)
        #expect(sample.gpuTemperature == nil)
        #expect(fixture.requested == ["FNum"])
    }

    @Test func mappedMissingAndInvalidSensorsDoNotProduceTemperature() {
        let fixture = SensorFixture()
        fixture.set("Te05", 0); fixture.set("Tp01", -1); fixture.set("Tg0G", 200)
        let sample = HardwareSensorReader(transport: fixture, model: "Mac16,10", cpuBrand: "Apple M4").sample()
        #expect(sample.cpuTemperature == nil)
        #expect(sample.gpuTemperature == nil)
    }

    @Test func liveSensorProbeReportsTypesWithoutRequiringSpecificHardware() {
        let transport = SMCReadOnlyTransport()
        for key in ["FNum", "F0Ac", "F1Ac", "Tp09", "Tp01", "Tg05"] {
            if let value = try? transport.read(key) {
                print("SMC只读探针 \(key) type=\(value.type) value=\(value.number.map(String.init(describing:)) ?? "unavailable")")
                #expect(value.bytes.count <= 32)
            }
        }
    }
}
