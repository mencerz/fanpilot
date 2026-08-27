import Foundation
import IOKit
import os

final class SMCWriter: @unchecked Sendable {
    private let log = Logger(subsystem: "com.oleksii.baliuk.fanpilot.helper", category: "smc")
    private let connection: io_connect_t
    private(set) var touchedFans: Set<Int> = []
    private var ownsThermalUnlock = false
    // The SMC does not accept the mode write immediately after the thermal
    // unlock; measured on an M4 it needs seconds, not milliseconds. A shorter
    // budget here simply never acquires the fan. Queue occupancy is bounded
    // instead by the ownership gate and the queue depth cap in the helper.
    private let manualModeRetryLimit = 30
    /// Keys are four characters, so a two-digit fan index would silently build
    /// a different key.
    private let maximumFanIndex = 10
    private let manualModeRetryDelay: TimeInterval = 0.1

    init?() {
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
    }

    deinit {
        restoreSystemControl()
        IOServiceClose(connection)
    }

    func setTargetRPM(fan: Int, requestedRPM: Int) -> Result<Int, SMCWriteError> {
        guard fan >= 0, fan < min(fanCount, maximumFanIndex) else { return .failure(.invalidFan) }
        guard let rawMinimum = readNumber("F\(fan)Mn"), rawMinimum.isFinite,
              let rawMaximum = readNumber("F\(fan)Mx"), rawMaximum.isFinite else {
            return .failure(.invalidRange)
        }
        let minimum = Int(rawMinimum.rounded())
        let maximum = Int(rawMaximum.rounded())
        guard minimum > 0, maximum >= minimum else { return .failure(.invalidRange) }
        let target = min(max(requestedRPM, minimum), maximum)

        guard enableManualMode(fan: fan) else {
            releaseThermalUnlockIfIdle()
            return .failure(.manualModeRejected)
        }
        touchedFans.insert(fan)
        guard writeNumber("F\(fan)Tg", value: Double(target)) else { return .failure(.targetRejected) }
        return .success(target)
    }

    /// A previous helper process can be killed while fans are still forced,
    /// and the SMC keeps that state until somebody clears it. Only fans that
    /// are actually still in manual mode are touched here.
    func recoverFromPreviousSession() {
        // A forced fan cannot be detected — the mode key does not read back the
        // value written to it — but a thermal unlock left set does read back,
        // and it only survives a process that died holding the fans. Absent
        // that evidence the SMC is left alone: writing to it on every launch
        // is exactly what "opening the app never touches hardware" rules out.
        guard readNumber("Ftst") == 1 else { return }
        log.notice("A previous session left the thermal unlock set; returning fans to macOS")
        for fan in 0..<max(0, min(fanCount, maximumFanIndex)) {
            _ = writeNumber("F\(fan)Md", value: 0)
        }
        let released = writeNumber("Ftst", value: 0)
        log.notice("Released the leftover thermal unlock: \(released, privacy: .public)")
    }

    @discardableResult
    func restoreSystemControl() -> Bool {
        var restored: Set<Int> = []
        var success = true
        for fan in touchedFans {
            // 0 is the value that hands the fan back to the thermal manager.
            // The mode key reads back as 3 while the fan is parked and 0 while
            // it spins, so it is a status, not a value worth restoring.
            if writeNumber("F\(fan)Md", value: 0) {
                restored.insert(fan)
            } else {
                success = false
                log.error("Fan \(fan, privacy: .public) did not return to system control")
            }
        }
        // Fans that refused to switch back stay on the list so the watchdog
        // keeps retrying instead of forgetting that they are still forced.
        touchedFans.subtract(restored)

        // The thermal unlock is what makes the mode key writable, so it is only
        // released once every fan is verified to be back under system control.
        success = releaseThermalUnlockIfIdle() && success
        if !restored.isEmpty {
            let list = restored.sorted().map(String.init).joined(separator: ", ")
            log.notice("Returned fans [\(list, privacy: .public)] to system control")
        }
        return success
    }

    /// Clearing the unlock is only attempted while no fan is still forced, and
    /// ownership is kept until the write actually succeeds so a failure retries.
    @discardableResult
    private func releaseThermalUnlockIfIdle() -> Bool {
        guard ownsThermalUnlock, touchedFans.isEmpty else { return true }
        guard writeNumber("Ftst", value: 0) else {
            log.error("Thermal unlock could not be released; will retry")
            return false
        }
        ownsThermalUnlock = false
        return true
    }

    private var fanCount: Int {
        guard let count = readNumber("FNum"), count.isFinite, count >= 0 else { return 0 }
        return Int(count)
    }

    private func enableManualMode(fan: Int) -> Bool {
        let currentMode = readNumber("F\(fan)Md").map(Int.init) ?? -1
        let currentRPM = readNumber("F\(fan)Ac").map(Int.init) ?? -1
        if writeNumber("F\(fan)Md", value: 1) { return true }
        log.notice("Fan \(fan, privacy: .public) refused manual mode directly (mode=\(currentMode, privacy: .public), rpm=\(currentRPM, privacy: .public))")
        guard writeNumber("Ftst", value: 1) else { return false }
        ownsThermalUnlock = true
        log.notice("Unlocked thermal test mode to force fan \(fan, privacy: .public)")

        // Bounded on purpose: this runs on the SMC queue, so every extra second
        // here also delays heartbeats and the return-to-System command, and the
        // app's XPC timeout has to stay comfortably above this budget.
        let start = Date()
        for attempt in 1...manualModeRetryLimit {
            if writeNumber("F\(fan)Md", value: 1) {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                log.notice("Fan \(fan, privacy: .public) accepted manual mode after \(attempt, privacy: .public) attempts, \(elapsed, privacy: .public) ms")
                return true
            }
            Thread.sleep(forTimeInterval: manualModeRetryDelay)
        }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let readBack = readNumber("F\(fan)Md").map { Int($0) } ?? -1
        log.error("Fan \(fan, privacy: .public) refused manual mode after \(self.manualModeRetryLimit, privacy: .public) attempts over \(elapsed, privacy: .public) ms (mode reads back \(readBack, privacy: .public), Ftst \(self.readNumber("Ftst").map { Int($0) } ?? -1, privacy: .public))")
        return false
    }

    private func readNumber(_ key: String) -> Double? {
        guard let info = keyInfo(key) else { return nil }
        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5
        guard call(&input) == KERN_SUCCESS, input.result == 0 else { return nil }
        return decode(input.bytes.array, type: info.dataType)
    }

    private func writeNumber(_ key: String, value: Double) -> Bool {
        guard let info = keyInfo(key), let encoded = encode(value, type: info.dataType) else { return false }
        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 6
        input.bytes = SMCBytes(encoded)
        return call(&input) == KERN_SUCCESS && input.result == 0
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
        var outputSize = inputSize
        let result = withUnsafePointer(to: &input) { source in
            withUnsafeMutablePointer(to: &output) { destination in
                IOConnectCallStructMethod(connection, 2, source, inputSize, destination, &outputSize)
            }
        }
        if result == KERN_SUCCESS { input = output }
        return result
    }

    private func decode(_ bytes: [UInt8], type: UInt32) -> Double? {
        switch type {
        case fourCharCode("flt "):
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes.prefix(4)) }
            return value.isFinite ? Double(value) : nil
        case fourCharCode("fpe2"):
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case fourCharCode("ui8 "):
            return Double(bytes[0])
        default:
            return nil
        }
    }

    private func encode(_ value: Double, type: UInt32) -> [UInt8]? {
        switch type {
        case fourCharCode("flt "):
            var float = Float(value)
            return withUnsafeBytes(of: &float) { Array($0) }
        case fourCharCode("fpe2"):
            let raw = UInt16(max(0, min(value * 4, Double(UInt16.max))))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case fourCharCode("ui8 "):
            return [UInt8(max(0, min(value, 255)))]
        default:
            return nil
        }
    }
}

enum SMCWriteError: LocalizedError {
    case invalidFan, invalidRange, manualModeRejected, targetRejected

    var errorDescription: String? {
        switch self {
        case .invalidFan: "Invalid fan identifier."
        case .invalidRange: "The firmware did not provide a safe RPM range."
        case .manualModeRejected: "The thermal manager rejected manual mode."
        case .targetRejected: "The SMC rejected the target RPM."
        }
    }
}

private func fourCharCode(_ string: String) -> UInt32 {
    string.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
}

private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0
    var reserved0: UInt8 = 0; var reserved1: UInt8 = 0; var reserved2: UInt8 = 0
}
private struct SMCBytes {
    var b0: UInt8 = 0; var b1: UInt8 = 0; var b2: UInt8 = 0; var b3: UInt8 = 0; var b4: UInt8 = 0; var b5: UInt8 = 0; var b6: UInt8 = 0; var b7: UInt8 = 0
    var b8: UInt8 = 0; var b9: UInt8 = 0; var b10: UInt8 = 0; var b11: UInt8 = 0; var b12: UInt8 = 0; var b13: UInt8 = 0; var b14: UInt8 = 0; var b15: UInt8 = 0
    var b16: UInt8 = 0; var b17: UInt8 = 0; var b18: UInt8 = 0; var b19: UInt8 = 0; var b20: UInt8 = 0; var b21: UInt8 = 0; var b22: UInt8 = 0; var b23: UInt8 = 0
    var b24: UInt8 = 0; var b25: UInt8 = 0; var b26: UInt8 = 0; var b27: UInt8 = 0; var b28: UInt8 = 0; var b29: UInt8 = 0; var b30: UInt8 = 0; var b31: UInt8 = 0

    init() {}
    init(_ bytes: [UInt8]) {
        let values = Array(bytes.prefix(32)) + Array(repeating: 0, count: max(0, 32 - bytes.count))
        (b0,b1,b2,b3,b4,b5,b6,b7) = (values[0],values[1],values[2],values[3],values[4],values[5],values[6],values[7])
        (b8,b9,b10,b11,b12,b13,b14,b15) = (values[8],values[9],values[10],values[11],values[12],values[13],values[14],values[15])
        (b16,b17,b18,b19,b20,b21,b22,b23) = (values[16],values[17],values[18],values[19],values[20],values[21],values[22],values[23])
        (b24,b25,b26,b27,b28,b29,b30,b31) = (values[24],values[25],values[26],values[27],values[28],values[29],values[30],values[31])
    }
    var array: [UInt8] { [b0,b1,b2,b3,b4,b5,b6,b7,b8,b9,b10,b11,b12,b13,b14,b15,b16,b17,b18,b19,b20,b21,b22,b23,b24,b25,b26,b27,b28,b29,b30,b31] }
}
private struct SMCParamStruct {
    var key: UInt32 = 0; var version = SMCVersion(); var pLimitData = SMCPLimitData(); var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0; var status: UInt8 = 0; var data8: UInt8 = 0; var data32: UInt32 = 0; var bytes = SMCBytes()
}
