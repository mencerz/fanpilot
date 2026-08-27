import Foundation
import IOKit

protocol HardwareMonitoring: Sendable {
    func readSnapshot() -> ThermalSnapshot
}

/// Read-only AppleSMC client. Fan writes are intentionally kept outside this
/// type so merely opening FanPilot can never alter hardware state.
final class SMCClient: HardwareMonitoring, @unchecked Sendable {
    private let connection: io_connect_t
    private var temperatureKeys: [String] = []

    init?() {
        // Newer Apple Silicon Macs expose the same SMC user client through
        // AppleSMCKeysEndpoint instead of the legacy AppleSMC service class.
        var service: io_service_t = 0
        for serviceClass in ["AppleSMC", "AppleSMCKeysEndpoint"] {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceClass))
            if service != 0 { break }
        }
        guard service != 0 else { return nil }
        var handle: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &handle)
        IOObjectRelease(service)
        guard result == KERN_SUCCESS else { return nil }
        connection = handle
        temperatureKeys = discoverTemperatureKeys()
    }

    deinit { IOServiceClose(connection) }

    func readSnapshot() -> ThermalSnapshot {
        let fallbackTemperatureKeys = ["TC0P", "TC0D", "Tp0P", "Tp1P", "TG0P", "TB0T"]
        let temperatureReadings = (temperatureKeys.isEmpty ? fallbackTemperatureKeys : temperatureKeys)
            .compactMap { key in readNumber(key: key).map { (key, $0) } }
            .filter { $0.1 >= 10 && $0.1 <= 110 }

        let groupedTemperatures = ["Tp", "Te", "Tg", "TB"].compactMap { prefix in
            robustAverage(temperatureReadings.filter { $0.0.hasPrefix(prefix) }.map(\.1))
        }

        let fanCount = Int(readNumber(key: "FNum") ?? 0)
        let fans = (0..<max(0, min(fanCount, 8))).compactMap { index -> FanReading? in
            guard let actual = readNumber(key: "F\(index)Ac"), actual.isFinite else { return nil }
            return FanReading(
                id: index,
                name: fanName(index: index, count: fanCount),
                currentRPM: Int(actual.rounded()),
                minimumRPM: Int((readNumber(key: "F\(index)Mn") ?? 0).rounded()),
                maximumRPM: Int((readNumber(key: "F\(index)Mx") ?? 0).rounded())
            )
        }

        return ThermalSnapshot(
            temperature: groupedTemperatures.max(),
            fans: fans,
            capturedAt: .now
        )
    }

    private func fanName(index: Int, count: Int) -> String {
        guard count > 1 else { return "Fan" }
        if index == 0 { return "Left fan" }
        if index == 1 { return "Right fan" }
        return "Fan \(index + 1)"
    }

    var discoveredTemperatureKeys: [String] { temperatureKeys }

    var discoveredTemperatureReadings: [(String, Double)] {
        temperatureKeys.compactMap { key in readNumber(key: key).map { (key, $0) } }
    }

    private func robustAverage(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let plausible = sorted.filter { abs($0 - median) <= 20 }
        guard !plausible.isEmpty else { return nil }
        return plausible.reduce(0, +) / Double(plausible.count)
    }

    private func discoverTemperatureKeys() -> [String] {
        guard let rawCount = readNumber(key: "#KEY") else { return [] }
        let count = min(max(Int(rawCount), 0), 10_000)
        var keys: [String] = []
        keys.reserveCapacity(128)

        for index in 0..<count {
            var input = SMCParamStruct()
            input.data8 = 8
            input.data32 = UInt32(index)
            guard call(&input) == KERN_SUCCESS, input.result == 0 else { continue }
            let key = fourCharString(input.key)
            guard key.hasPrefix("T"),
                  key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tg") || key.hasPrefix("TB"),
                  let info = keyInfo(key),
                  info.dataType == fourCharCode("flt ") || info.dataType == fourCharCode("sp78") else { continue }
            keys.append(key)
        }
        return keys
    }

    func diagnosticDescription(for key: String) -> String {
        var infoRequest = SMCParamStruct()
        infoRequest.key = fourCharCode(key)
        infoRequest.data8 = 9
        let infoResult = call(&infoRequest)
        let type = String(bytes: [
            UInt8((infoRequest.keyInfo.dataType >> 24) & 0xff),
            UInt8((infoRequest.keyInfo.dataType >> 16) & 0xff),
            UInt8((infoRequest.keyInfo.dataType >> 8) & 0xff),
            UInt8(infoRequest.keyInfo.dataType & 0xff)
        ], encoding: .ascii) ?? "????"
        guard infoResult == KERN_SUCCESS else {
            return "\(key): keyInfo kern=\(String(format: "0x%08x", infoResult)), structSize=\(MemoryLayout<SMCParamStruct>.size), stride=\(MemoryLayout<SMCParamStruct>.stride)"
        }

        var readRequest = SMCParamStruct()
        readRequest.key = fourCharCode(key)
        readRequest.keyInfo.dataSize = infoRequest.keyInfo.dataSize
        readRequest.data8 = 5
        let readResult = call(&readRequest)
        let bytes = readRequest.bytes.array.prefix(Int(min(infoRequest.keyInfo.dataSize, 8)))
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
        return "\(key): type=\(type), size=\(infoRequest.keyInfo.dataSize), infoResult=\(infoRequest.result), infoStatus=\(infoRequest.status), readKern=\(String(format: "0x%08x", readResult)), readResult=\(readRequest.result), readStatus=\(readRequest.status), bytes=[\(bytes)]"
    }

    private func readNumber(key: String) -> Double? {
        guard let info = keyInfo(key) else { return nil }
        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5
        // The driver reports per-key failures in `result`; without this a
        // rejected read is decoded from whatever happens to be in the buffer.
        guard call(&input) == KERN_SUCCESS, input.result == 0 else { return nil }

        let bytes = input.bytes.array
        switch info.dataType {
        case fourCharCode("sp78"):
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case fourCharCode("fpe2"):
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case fourCharCode("flt "):
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: bytes.prefix(4))
            }
            return value.isFinite ? Double(value) : nil
        case fourCharCode("ui8 "):
            return Double(bytes[0])
        case fourCharCode("ui16"):
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case fourCharCode("ui32"):
            return Double(
                UInt32(bytes[0]) << 24 |
                UInt32(bytes[1]) << 16 |
                UInt32(bytes[2]) << 8 |
                UInt32(bytes[3])
            )
        default:
            return nil
        }
    }

    private func keyInfo(_ key: String) -> SMCKeyInfoData? {
        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.data8 = 9
        guard call(&input) == KERN_SUCCESS, input.result == 0, input.keyInfo.dataSize > 0 else { return nil }
        return input.keyInfo
    }

    private func call(_ input: inout SMCParamStruct) -> kern_return_t {
        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        return withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(connection, 2, inputPointer, inputSize, outputPointer, &outputSize)
            }
        }.mapOutput(from: output, into: &input)
    }
}

private extension kern_return_t {
    func mapOutput(from output: SMCParamStruct, into input: inout SMCParamStruct) -> kern_return_t {
        if self == KERN_SUCCESS { input = output }
        return self
    }
}

private func fourCharCode(_ string: String) -> UInt32 {
    string.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
}

private func fourCharString(_ value: UInt32) -> String {
    String(bytes: [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ], encoding: .ascii) ?? ""
}

private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // Matches the three bytes of tail padding in Apple's C ABI. Swift does
    // not automatically include that padding when this struct is nested.
    var reserved0: UInt8 = 0
    var reserved1: UInt8 = 0
    var reserved2: UInt8 = 0
}

private struct SMCBytes {
    var b0: UInt8 = 0; var b1: UInt8 = 0; var b2: UInt8 = 0; var b3: UInt8 = 0; var b4: UInt8 = 0; var b5: UInt8 = 0; var b6: UInt8 = 0; var b7: UInt8 = 0
    var b8: UInt8 = 0; var b9: UInt8 = 0; var b10: UInt8 = 0; var b11: UInt8 = 0; var b12: UInt8 = 0; var b13: UInt8 = 0; var b14: UInt8 = 0; var b15: UInt8 = 0
    var b16: UInt8 = 0; var b17: UInt8 = 0; var b18: UInt8 = 0; var b19: UInt8 = 0; var b20: UInt8 = 0; var b21: UInt8 = 0; var b22: UInt8 = 0; var b23: UInt8 = 0
    var b24: UInt8 = 0; var b25: UInt8 = 0; var b26: UInt8 = 0; var b27: UInt8 = 0; var b28: UInt8 = 0; var b29: UInt8 = 0; var b30: UInt8 = 0; var b31: UInt8 = 0

    var array: [UInt8] {
        [b0,b1,b2,b3,b4,b5,b6,b7,b8,b9,b10,b11,b12,b13,b14,b15,b16,b17,b18,b19,b20,b21,b22,b23,b24,b25,b26,b27,b28,b29,b30,b31]
    }
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var version = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCBytes()
}
