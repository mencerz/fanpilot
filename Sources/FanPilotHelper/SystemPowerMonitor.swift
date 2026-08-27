import Foundation
import IOKit.pwr_mgt

private let ioMessageCanSystemSleep: UInt32 = 0xe000_0270
private let ioMessageSystemWillSleep: UInt32 = 0xe000_0280

final class SystemPowerMonitor: @unchecked Sendable {
    private let willSleep: @Sendable () -> Void
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init?(willSleep: @escaping @Sendable () -> Void) {
        self.willSleep = willSleep
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notificationPort,
            systemPowerCallback,
            &notifier
        )
        guard rootPort != 0,
              let notificationPort,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() else {
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    fileprivate func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case ioMessageCanSystemSleep, ioMessageSystemWillSleep:
            willSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        default:
            break
        }
    }
}

private let systemPowerCallback: IOServiceInterestCallback = { refcon, _, messageType, argument in
    guard let refcon else { return }
    Unmanaged<SystemPowerMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .handle(messageType: messageType, argument: argument)
}
