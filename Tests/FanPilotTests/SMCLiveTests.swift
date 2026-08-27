import Foundation
import IOKit
import Testing
@testable import FanPilot

@Test(.enabled(if: ProcessInfo.processInfo.environment["FANPILOT_LIVE_SMC_TEST"] == "1"))
func liveSMCSnapshot() {
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
    print("Snapshot: \(String(describing: client?.readSnapshot()))")
}
