import Foundation
import Darwin
import IOKit.ps
import SystemConfiguration

public struct DiskSample: Sendable, Codable {
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let volumeName: String
    public var usedBytes: UInt64 { totalBytes - min(totalBytes, availableBytes) }
}

public struct BatterySample: Sendable, Codable {
    public let isPresent: Bool
    public let chargePercent: Double?
    public let isCharging: Bool?
    public let isExternalPower: Bool?
}

public struct NetworkSample: Sendable, Codable {
    public let interfaceNames: [String]
    public let receivedBytesPerSecond: Double?
    public let sentBytesPerSecond: Double?
}

public enum MemoryPressure: String, Sendable, Codable {
    case normal, warning, critical
}

struct NetworkCounters: Equatable {
    let received: UInt64
    let sent: UInt64
}

struct NetworkRateTracker {
    private var previous: (interfaces: [String: NetworkCounters], time: Double)?

    mutating func sample(_ counters: [String: NetworkCounters]?, time: Double) -> NetworkSample? {
        guard let counters else { previous = nil; return nil }
        defer { previous = (counters, time) }
        let names = counters.keys.sorted()
        let unknown = NetworkSample(interfaceNames: names, receivedBytesPerSecond: nil, sentBytesPerSecond: nil)
        // 首帧、断网/切网、休眠和计数回退重建基线，避免显示累计流量或睡眠平均值。
        guard !names.isEmpty, let previous, previous.interfaces.keys.sorted() == names else { return unknown }
        let elapsed = time - previous.time
        guard elapsed > 0, elapsed <= 15, elapsed.isFinite else { return unknown }
        var received = 0.0
        var sent = 0.0
        for name in names {
            guard let current = counters[name], let old = previous.interfaces[name], current.received >= old.received, current.sent >= old.sent else { return unknown }
            received += Double(current.received - old.received)
            sent += Double(current.sent - old.sent)
        }
        return NetworkSample(interfaceNames: names, receivedBytesPerSecond: received / elapsed, sentBytesPerSecond: sent / elapsed)
    }
}

struct SystemMetricsReader {
    private var networkTracker = NetworkRateTracker()

    static func readDisk() -> DiskSample? {
        // 统一使用用户目录所在卷的普通可用容量与总容量，不混用“重要用途可清理容量”。
        let url = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
              total > 0, available >= 0, available <= total else { return nil }
        return DiskSample(totalBytes: UInt64(total), availableBytes: UInt64(available), volumeName: values.volumeName ?? "启动磁盘")
    }

    static func battery(from descriptions: [[String: Any]], externalPower: Bool?) -> BatterySample? {
        // IOPowerSources 也列出 UPS，只有 InternalBattery 才是本机电池。
        guard let battery = descriptions.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else {
            return BatterySample(isPresent: false, chargePercent: nil, isCharging: nil, isExternalPower: externalPower)
        }
        guard let present = battery[kIOPSIsPresentKey] as? Bool else { return nil }
        guard present else { return BatterySample(isPresent: false, chargePercent: nil, isCharging: nil, isExternalPower: externalPower) }
        let current = (battery[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
        let maximum = (battery[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
        let percentage: Double?
        // SDK IOPSKeys.h 明确 Current/Max 同单位；Max 通常为100，并非电池健康度。
        if let current, let maximum, current.isFinite, maximum.isFinite, maximum > 0, current >= 0, current <= maximum {
            percentage = current / maximum * 100
        } else { percentage = nil }
        let state = battery[kIOPSPowerSourceStateKey] as? String
        let external = state == kIOPSACPowerValue ? true : state == kIOPSBatteryPowerValue ? false : externalPower
        return BatterySample(isPresent: true, chargePercent: percentage, isCharging: battery[kIOPSIsChargingKey] as? Bool, isExternalPower: external)
    }

    static func readBattery() -> BatterySample? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var descriptions: [[String: Any]] = []
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any] else { return nil }
            descriptions.append(description)
        }
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return battery(from: descriptions, externalPower: source == kIOPSACPowerValue ? true : source == kIOPSBatteryPowerValue ? false : nil)
    }

    static func memoryPressure(rawValue: Int32) -> MemoryPressure? {
        // XNU kern_memorystatus_notify.c 的 sysctl 将内核枚举转换为 dispatch flags，非内部0/1/2/3枚举。
        switch rawValue {
        case Int32(DispatchSource.MemoryPressureEvent.normal.rawValue): .normal
        case Int32(DispatchSource.MemoryPressureEvent.warning.rawValue): .warning
        case Int32(DispatchSource.MemoryPressureEvent.critical.rawValue): .critical
        default: nil
        }
    }

    static func readMemoryPressure() -> MemoryPressure? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        return memoryPressure(rawValue: value)
    }

    static func readBootTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }

    static func readHardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size < 1024 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    mutating func readNetwork() -> NetworkSample? {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let time = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        return networkTracker.sample(Self.networkCounters(), time: time)
    }

    private static func networkCounters() -> [String: NetworkCounters]? {
        // 仅计系统识别的物理 Wi-Fi/以太网，过滤 utun、lo、awdl 等，避免 VPN 内外层重复计量。
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
              let store = SCDynamicStoreCreate(nil, "Ermi.NetworkMetrics" as CFString, nil, nil) else { return nil }
        let physical = Set(interfaces.compactMap { interface -> String? in
            guard let type = SCNetworkInterfaceGetInterfaceType(interface),
                  type == kSCNetworkInterfaceTypeEthernet || type == kSCNetworkInterfaceTypeIEEE80211 else { return nil }
            guard let name = SCNetworkInterfaceGetBSDName(interface) else { return nil }
            // IFF_RUNNING 只表示驱动已分配资源；拔线接口仍可能为真，必须检查实际链路状态。
            let key = SCDynamicStoreKeyCreateNetworkInterfaceEntity(nil, kSCDynamicStoreDomainState, name, kSCEntNetLink)
            guard let link = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                  link[kSCPropNetLinkActive as String] as? Bool == true else { return nil }
            return name as String
        })
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return bytes.withUnsafeBytes { buffer in
            var result: [String: NetworkCounters] = [:]
            var offset = 0
            while offset + 4 <= size {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= size else { return nil }
                let type = buffer[offset + 3]
                if type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                        let name = String(decoding: nameBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if physical.contains(name), message.ifm_flags & IFF_UP != 0, message.ifm_flags & IFF_RUNNING != 0 {
                            // NET_RT_IFLIST2 提供64位累计字节，getifaddrs的32位计数高速传输时易回绕。
                            result[name] = NetworkCounters(received: message.ifm_data.ifi_ibytes, sent: message.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += length
            }
            return result
        }
    }
}
