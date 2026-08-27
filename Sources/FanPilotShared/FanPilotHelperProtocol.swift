import Foundation
import Security

public let fanPilotAppIdentifier = "com.oleksii.baliuk.fanpilot.app"
public let fanPilotHelperIdentifier = "com.oleksii.baliuk.fanpilot.helper"
public let fanPilotHelperMachService = fanPilotHelperIdentifier
public let fanPilotHelperPlistName = "\(fanPilotHelperIdentifier).plist"

/// Daemons registered by earlier builds keep running under their old label
/// until they are explicitly unregistered, so the app removes them on launch.
public let legacyFanPilotHelperPlistNames = ["com.fanpilot.helper.plist"]

@objc public protocol FanPilotHelperProtocol {
    func status(reply: @escaping @Sendable (Bool, String?) -> Void)
    func setSystemMode(reply: @escaping @Sendable (Bool, String?) -> Void)
    func setTargetRPM(fan: Int, rpm: Int, reply: @escaping @Sendable (Bool, Int, String?) -> Void)
    func heartbeat(reply: @escaping @Sendable (Bool) -> Void)
}

/// The XPC peer requirement. `identifier` alone is satisfied by any ad-hoc
/// signature, so as soon as this build is signed with a real certificate the
/// requirement is tightened to that team automatically.
public func fanPilotCodeRequirement(identifier: String) -> String {
    guard let team = fanPilotTeamIdentifier() else { return "identifier \"\(identifier)\"" }
    return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
}

public func fanPilotTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let dictionary = information as? [String: Any] else { return nil }
    return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
}
