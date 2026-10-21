import Foundation
import IOKit
import Darwin

struct SMCValue {
    let key: String
    let type: String
    let bytes: [UInt8]

    var number: Double? {
        let value: Double
        switch (type, bytes.count) {
        case ("ui8 ", 1): value = Double(bytes[0])
        case ("ui16", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("ui32", 4): value = Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case ("flt ", 4):
            // Apple Silicon SMC 的 flt 是小端 IEEE754；整数和定点仍为大端。
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
            value = Double(Float(bitPattern: bits))
        case ("fpe2", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("sp78", 2): value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
        return value.isFinite ? value : nil
    }

    var isTemperature: Bool { type == "sp78" || type == "flt " }

    var temperatureCelsius: Double? {
        // 候选和 helper 的定向读取共用严格温度规则；不接受整数/RPM 类型伪装温度。
        guard isTemperature, let value = number, value > 0, value <= 150 else { return nil }
        return value
    }

    var fanName: String? {
        // {fds 前4字节为风扇描述头，后续12字节为名称；ch8* 直接为字符串。
        let text: [UInt8]
        if type == "{fds", bytes.count == 16 { text = Array(bytes.dropFirst(4)) }
        else if type == "ch8*" { text = bytes }
        else { return nil }
        let result = String(decoding: text.prefix(while: { $0 != 0 }), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

protocol SMCKeyReading {
    func read(_ key: String) throws -> SMCValue
    func allKeys() throws -> [String]
}
extension SMCKeyReading {
    // 旧 fixture 和不支持枚举的读取器仍可完成既有定向采样。
    func allKeys() throws -> [String] { [] }
}
protocol SMCKeyWriting: SMCKeyReading { func write(_ value: SMCValue) throws }

enum SMCReadError: Error {
    case unavailable, invalidKey, malformedResponse, missingKey, firmware(UInt8), kernel(Int32)
}

// 固定80字节协议布局独立于 Swift 嵌套结构的尾部 padding。普通采样器仍只依赖读协议；
// 写入口仅内部风扇设备使用，限制root与明确白名单，不向XPC暴露key或任意命令。
final class SMCReadOnlyTransport: SMCKeyWriting {
    private var connection: io_connect_t = 0
    private var metadata: [String: (size: Int, type: String)] = [:]
    private var retryAfter: TimeInterval = 0
    private enum Command: UInt8 { case metadata = 9, payload = 5, write = 6, readIndex = 8 }
    private let exchange: (([UInt8]) throws -> [UInt8])?
    init(exchange: (([UInt8]) throws -> [UInt8])? = nil) { self.exchange = exchange }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read(_ key: String) throws -> SMCValue {
        guard key.utf8.count == 4, key.utf8.allSatisfy({ $0 < 128 }) else { throw SMCReadError.invalidKey }
        try openIfNeeded()
        let info: (size: Int, type: String)
        if let cached = metadata[key] { info = cached }
        else {
            let response = try call(key: key, command: .metadata)
            let size = Int(Self.uint32(response, at: 28))
            guard (1...32).contains(size) else { throw SMCReadError.malformedResponse }
            let typeCode = Self.uint32(response, at: 32)
            let type = String(decoding: [24,16,8,0].map { UInt8((typeCode >> $0) & 255) }, as: UTF8.self)
            info = (size, type)
        }
        let response = try call(key: key, command: .payload, size: info.size)
        metadata[key] = info
        return SMCValue(key: key, type: info.type, bytes: Array(response[48..<(48 + info.size)]))
    }

    func allKeys() throws -> [String] {
        // Stats SMC/smc.swift（bda3a013）：#KEY 给出数量，命令8以 data32 索引读取 output.key。
        // 只读发现设4096项上限；此方法仅由 App 候选采样按需调用，helper 不枚举。
        let countValue = try read("#KEY")
        guard countValue.type == "ui32", let count = countValue.number else { throw SMCReadError.malformedResponse }
        var keys: [String] = []
        for index in 0..<min(Int(count), 4096) {
            do {
                let response = try call(key: "", command: .readIndex, index: UInt32(index))
                let code = Self.uint32(response, at: 0)
                keys.append(String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 255) }, as: UTF8.self))
            } catch SMCReadError.missingKey { continue }
            catch SMCReadError.firmware { continue }
        }
        return keys
    }

    func write(_ value: SMCValue) throws {
        guard geteuid() == 0, value.key == "Ftst" || value.key == "FS! " || value.key.range(of: "^F[0-9](md|Md|Tg)$", options: .regularExpression) != nil else { throw SMCReadError.invalidKey }
        // 重新读取metadata与payload，拒绝调用方改变驱动声明的类型或长度。
        let current = try read(value.key)
        guard current.type == value.type, current.bytes.count == value.bytes.count else { throw SMCReadError.malformedResponse }
        _ = try call(key: value.key, command: .write, size: value.bytes.count, payload: value.bytes)
    }

    private func openIfNeeded() throws {
        // 测试只替换 IOKit 交换边界，仍验证真实80字节请求及响应校验，不访问设备。
        if exchange != nil || connection != 0 { return }
        guard ProcessInfo.processInfo.systemUptime >= retryAfter else { throw SMCReadError.unavailable }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { retryAfter = ProcessInfo.processInfo.systemUptime + 5; throw SMCReadError.unavailable }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            connection = 0
            retryAfter = ProcessInfo.processInfo.systemUptime + 5
            throw SMCReadError.kernel(result)
        }
    }

    private func call(key: String, command: Command, size: Int = 0, payload: [UInt8] = [], index: UInt32 = 0) throws -> [UInt8] {
        var request = [UInt8](repeating: 0, count: 80)
        var response = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        Self.store(code, in: &request, at: 0)
        Self.store(UInt32(size), in: &request, at: 28)
        request[42] = command.rawValue
        Self.store(index, in: &request, at: 44)
        for (index, byte) in payload.enumerated() { request[48 + index] = byte }
        var outputSize = 80
        if let exchange {
            response = try exchange(request)
            outputSize = response.count
        } else {
            let result = request.withUnsafeBytes { input in
                response.withUnsafeMutableBytes { output in
                    IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count, output.baseAddress, &outputSize)
                }
            }
            guard result == KERN_SUCCESS else {
                // 睡眠或驱动重启后丢弃旧连接及元数据，稍后重连；不沿用上次成功读数。
                IOServiceClose(connection); connection = 0; metadata.removeAll()
                retryAfter = ProcessInfo.processInfo.systemUptime + 5
                throw SMCReadError.kernel(result)
            }
        }
        guard outputSize >= (command == .write ? 48 : 48 + size), outputSize <= 80 else { throw SMCReadError.malformedResponse }
        guard response[40] == 0 else {
            metadata.removeValue(forKey: key)
            if response[40] == 0x84 { throw SMCReadError.missingKey }
            throw SMCReadError.firmware(response[40])
        }
        return response
    }
    private static func store(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (i * 8)) & 255) }
    }
    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) }
    }
}
