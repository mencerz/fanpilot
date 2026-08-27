import Foundation
import IOKit
import Testing
@testable import FanPilot

/// A hardware probe rather than a unit test: it is opt-in because it needs a
/// real SMC, and it prints what it found so an unsupported Mac can be
/// diagnosed from the output.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FANPILOT_LIVE_SMC_TEST"] == "1"))
func liveSMCSnapshot() throws {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint"))
    var connection: io_connect_t = 0
    let openResult = service == 0 ? kern_return_t(KERN_FAILURE) : IOServiceOpen(service, mach_task_self_, 0, &connection)
    print("Endpoint service: \(service), open result: \(String(format: "0x%08x", openResult)), connection: \(connection)")
    if connection != 0 { IOServiceClose(connection) }
    if service != 0 { IOObjectRelease(service) }
    let client = SMCClient()
    print("SMC connected: \(client != nil)")
    for key in ["FNum", "F0Ac", "F0Mn", "F0Mx", "F0Md", "Tp0P", "TB0T"] {
        if let client { print(client.diagnosticDescription(for: key)) }
    }
    print("Temperature keys: \(client?.discoveredTemperatureKeys ?? [])")
    print("Temperature readings: \(client?.discoveredTemperatureReadings ?? [])")
    let snapshot = try #require(client?.readSnapshot())
    print("Snapshot: \(snapshot)")

    // Whatever this Mac exposes, the reading has to be plausible rather than
    // decoded from a rejected read.
    if let temperature = snapshot.temperature {
        #expect((10...110).contains(temperature))
    }
    for fan in snapshot.fans {
        #expect(fan.minimumRPM > 0)
        #expect(fan.maximumRPM >= fan.minimumRPM)
        #expect(fan.currentRPM >= 0)
    }
}
