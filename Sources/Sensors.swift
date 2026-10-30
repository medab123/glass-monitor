import Foundation
import IOKit

struct SensorReading: Equatable {
    /// Average of the CPU performance- and efficiency-core sensors, °C.
    var cpu: Double?
    /// Average of the GPU sensors, °C.
    var gpu: Double?
    /// Fastest fan, rpm (0 = fans idle); nil on fanless Macs.
    var fanRPM: Double?
    var fanMaxRPM: Double?
}

/// Temperatures and fan speeds from the System Management Controller, the same source Stats and
/// iStat Menus use. macOS has no public API for these: this talks to the AppleSMC IOKit service.
/// Keys are discovered once (≈0.4 s), then only the relevant ones are read.
final class SMCSensors {
    private struct Key {
        let code: UInt32
        let size: UInt32
        let type: UInt32
    }

    /// Mirrors the C `SMCKeyData_t` struct the AppleSMC user client expects (80 bytes).
    private struct Param {
        var key: UInt32 = 0
        var versMajor: UInt8 = 0, versMinor: UInt8 = 0, versBuild: UInt8 = 0, versReserved: UInt8 = 0
        var versRelease: UInt16 = 0
        var pad0: UInt16 = 0
        var limitVersion: UInt16 = 0, limitLength: UInt16 = 0
        var cpuLimit: UInt32 = 0, gpuLimit: UInt32 = 0, memLimit: UInt32 = 0
        var dataSize: UInt32 = 0, dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0, pad3: UInt8 = 0
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0, pad4: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case read = 5, keyAtIndex = 8, keyInfo = 9
    }

    private static let handleEvent: UInt32 = 2
    private static let float = fourCC("flt ")
    /// CPU cores on Apple Silicon (performance "Tp", efficiency "Te") and Intel ("TC").
    private static let cpuPrefixes = ["Tp", "Te", "TC0"]
    private static let gpuPrefixes = ["Tg", "TG0"]

    private var connection: io_connect_t = 0
    private var cpuKeys: [Key] = []
    private var gpuKeys: [Key] = []
    private var fanKeys: [Key] = []
    /// Doesn't change, so read once.
    private var fanMaxRPM: Double?

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { connection = 0; return }
        discover()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func read() -> SensorReading {
        guard connection != 0 else { return SensorReading() }
        let fans = fanKeys.compactMap(value)
        return SensorReading(cpu: average(cpuKeys), gpu: average(gpuKeys),
                             fanRPM: fans.isEmpty ? nil : fans.max(), fanMaxRPM: fanMaxRPM)
    }

    private func discover() {
        guard let count = info(Self.fourCC("#KEY")).flatMap({ bytes(of: $0) })?.reduce(0, { $0 << 8 | UInt32($1) }) else { return }
        for index in 0..<count {
            var input = Param()
            input.command = Command.keyAtIndex.rawValue
            input.index = index
            guard let code = call(&input)?.key, let key = info(code), key.type == Self.float, key.size == 4 else { continue }
            let name = Self.name(code)
            if Self.cpuPrefixes.contains(where: name.hasPrefix) {
                cpuKeys.append(key)
            } else if Self.gpuPrefixes.contains(where: name.hasPrefix) {
                gpuKeys.append(key)
            } else if name.hasPrefix("F"), name.hasSuffix("Ac") {
                fanKeys.append(key)
            } else if name.hasPrefix("F"), name.hasSuffix("Mx"), let max = value(key) {
                fanMaxRPM = Swift.max(fanMaxRPM ?? 0, max)
            }
        }
        // Drop sensors that aren't wired up on this model (they read 0 or nonsense).
        cpuKeys = cpuKeys.filter { value($0).map(Self.plausible) ?? false }
        gpuKeys = gpuKeys.filter { value($0).map(Self.plausible) ?? false }
    }

    private static func plausible(_ celsius: Double) -> Bool { celsius > 5 && celsius < 130 }

    private func average(_ keys: [Key]) -> Double? {
        let values = keys.compactMap(value).filter(Self.plausible)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func value(_ key: Key) -> Double? {
        guard let raw = bytes(of: key), raw.count == 4 else { return nil }
        return Double(raw.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
    }

    private func info(_ code: UInt32) -> Key? {
        var input = Param()
        input.key = code
        input.command = Command.keyInfo.rawValue
        guard let output = call(&input) else { return nil }
        return Key(code: code, size: output.dataSize, type: output.dataType)
    }

    private func bytes(of key: Key) -> [UInt8]? {
        var input = Param()
        input.key = key.code
        input.dataSize = key.size
        input.command = Command.read.rawValue
        guard let output = call(&input) else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(key.size, 32)))) }
    }

    private func call(_ input: inout Param) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(connection, Self.handleEvent, &input, MemoryLayout<Param>.stride, &output, &size)
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func name(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
}
