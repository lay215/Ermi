import Testing
import Foundation
import IOKit.ps
@testable import ErmiCore

struct SystemMetricsTests {
    @Test func networkUsesByteDeltasAndResetsAcrossTransitions() {
        var tracker = NetworkRateTracker()
        func counters(_ received: UInt64, _ sent: UInt64, name: String = "en0") -> [String: NetworkCounters] {
            [name: NetworkCounters(received: received, sent: sent)]
        }
        #expect(tracker.sample(counters(100, 50), time: 1)?.receivedBytesPerSecond == nil)
        let next = tracker.sample(counters(300, 90), time: 3)
        #expect(next?.receivedBytesPerSecond == 100)
        #expect(next?.sentBytesPerSecond == 20)
        #expect(tracker.sample(counters(400, 100, name: "en1"), time: 5)?.receivedBytesPerSecond == nil)
        #expect(tracker.sample(counters(1, 1, name: "en1"), time: 7)?.receivedBytesPerSecond == nil)
        #expect(tracker.sample(counters(500, 500, name: "en1"), time: 40)?.receivedBytesPerSecond == nil)
        #expect(tracker.sample(nil, time: 41) == nil)
        #expect(tracker.sample(counters(501, 501, name: "en1"), time: 42)?.receivedBytesPerSecond == nil)
        #expect(tracker.sample([:], time: 44)?.interfaceNames.isEmpty == true)
    }

    @Test func networkAggregatesEachPhysicalInterfaceOnce() {
        var tracker = NetworkRateTracker()
        _ = tracker.sample(["en0": .init(received: 100, sent: 100), "en1": .init(received: 200, sent: 200)], time: 1)
        let value = tracker.sample(["en0": .init(received: 200, sent: 200), "en1": .init(received: 500, sent: 300)], time: 3)
        #expect(value?.receivedBytesPerSecond == 200)
        #expect(value?.sentBytesPerSecond == 100)
    }

    @Test func batteryUsesCapacityRatioAndDistinguishesMissingBattery() {
        var battery: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true, kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 80, kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        let value = SystemMetricsReader.battery(from: [battery], externalPower: nil)
        #expect(value?.chargePercent == 50)
        #expect(value?.isCharging == false)
        #expect(value?.isExternalPower == true)
        battery[kIOPSMaxCapacityKey] = 0
        #expect(SystemMetricsReader.battery(from: [battery], externalPower: nil)?.chargePercent == nil)
        battery[kIOPSIsPresentKey] = false
        #expect(SystemMetricsReader.battery(from: [battery], externalPower: true)?.isPresent == false)
        #expect(SystemMetricsReader.battery(from: [[kIOPSTypeKey: kIOPSUPSType]], externalPower: true)?.isPresent == false)
        #expect(SystemMetricsReader.battery(from: [[kIOPSTypeKey: kIOPSInternalBatteryType]], externalPower: nil) == nil)
    }

    @Test func pressureUsesDispatchFlagsNotUsageRatioOrInternalEnums() {
        #expect(SystemMetricsReader.memoryPressure(rawValue: 1) == .normal)
        #expect(SystemMetricsReader.memoryPressure(rawValue: 2) == .warning)
        #expect(SystemMetricsReader.memoryPressure(rawValue: 4) == .critical)
        #expect(SystemMetricsReader.memoryPressure(rawValue: 0) == nil)
        #expect(SystemMetricsReader.memoryPressure(rawValue: 3) == nil)
        #expect(SystemMetricsReader.memoryPressure(rawValue: 99) == nil)
    }

    @Test func liveMetricsAreReadOnlyAndCoherent() async throws {
        let sampler = SystemSampler()
        let value = await sampler.sample()
        let disk = try #require(value.disk)
        #expect(disk.totalBytes >= disk.availableBytes)
        #expect(disk.usedBytes + disk.availableBytes == disk.totalBytes)
        #expect(value.bootTime.map { $0 <= Date() } == true)
        #expect(value.hardwareModel?.isEmpty == false)
        // 探针记录实际可用性，不把无电池/不支持接口的机器当成失败。
        print("METRICS_PROBE disk=\(disk.availableBytes)/\(disk.totalBytes) battery=\(String(describing: value.battery)) network=\(String(describing: value.network)) pressure=\(String(describing: value.memoryPressure)) model=\(value.hardwareModel ?? "nil") boot=\(String(describing: value.bootTime))")
        try await Task.sleep(for: .seconds(2))
        let next = await sampler.sample()
        print("METRICS_PROBE network_second=\(String(describing: next.network))")
        if let received = next.network?.receivedBytesPerSecond { #expect(received >= 0 && received.isFinite) }
    }
}
