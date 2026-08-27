import Foundation
import os
import FanPilotShared

final class FanPilotHelper: NSObject, FanPilotHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: fanPilotHelperIdentifier, category: "helper")
    private let writer = SMCWriter()
    private let queue = DispatchQueue(label: "\(fanPilotHelperIdentifier).smc")
    private var lastHeartbeat = Date()
    private var powerMonitor: SystemPowerMonitor?

    override init() {
        super.init()
        queue.async { [writer, log] in
            guard let writer else {
                log.error("Unable to open AppleSMC")
                return
            }
            writer.recoverFromPreviousSession()
        }
        powerMonitor = SystemPowerMonitor { [weak self] in
            _ = self?.queue.sync {
                self?.writer?.restoreSystemControl()
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self {
                Thread.sleep(forTimeInterval: 2)
                self.queue.async {
                    if Date().timeIntervalSince(self.lastHeartbeat) > 6,
                       !(self.writer?.touchedFans.isEmpty ?? true) {
                        self.log.notice("Heartbeat timed out, returning fan control to macOS")
                        self.writer?.restoreSystemControl()
                    }
                }
            }
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(fanPilotCodeRequirement(identifier: fanPilotAppIdentifier))
        connection.exportedInterface = NSXPCInterface(with: FanPilotHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func status(reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async { [writer] in
            reply(writer != nil, writer == nil ? "Unable to open AppleSMC." : nil)
        }
    }

    func setSystemMode(reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async { [writer] in
            guard let writer else { reply(false, "Unable to open AppleSMC."); return }
            let success = writer.restoreSystemControl()
            self.log.notice("System mode requested by the app: \(success, privacy: .public)")
            reply(success, success ? nil : "SMC did not confirm System mode.")
        }
    }

    func setTargetRPM(fan: Int, rpm: Int, reply: @escaping @Sendable (Bool, Int, String?) -> Void) {
        queue.async { [weak self] in
            guard let self, let writer = self.writer else { reply(false, 0, "Unable to open AppleSMC."); return }
            self.lastHeartbeat = .now
            switch writer.setTargetRPM(fan: fan, requestedRPM: rpm) {
            case .success(let applied): reply(true, applied, nil)
            case .failure(let error): reply(false, 0, error.localizedDescription)
            }
        }
    }

    func heartbeat(reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            self?.lastHeartbeat = .now
            reply(self != nil)
        }
    }
}

@main
struct FanPilotHelperMain {
    static func main() {
        let helper = FanPilotHelper()
        let listener = NSXPCListener(machServiceName: fanPilotHelperMachService)
        listener.delegate = helper
        listener.resume()
        RunLoop.current.run()
    }
}
