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
