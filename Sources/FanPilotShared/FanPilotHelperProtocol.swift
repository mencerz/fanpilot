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

/// The XPC peer requirement, or nil when the peer cannot be pinned — in which
/// case the caller must refuse to talk rather than accept a weaker check.
///
/// A signed build is pinned to its team. An ad-hoc build has no certificate to
/// anchor to, and `identifier` alone is worthless there: a code-signing
/// identifier is an attacker-chosen string, so any local process can sign
/// itself as this app and reach a root helper that trusts it. Development
/// builds are therefore pinned to the exact code hash of the peer binary that
/// shipped in the same bundle.
public func fanPilotCodeRequirement(identifier: String, pinnedTo peer: URL?) -> String? {
    if let team = fanPilotTeamIdentifier() {
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
    guard let peer, let hash = fanPilotCodeHash(of: peer) else { return nil }
    return "cdhash H\"\(hash)\""
}

/// The code directory hash of an on-disk binary or bundle, as the hex string a
/// `cdhash` requirement expects.
public func fanPilotCodeHash(of url: URL) -> String? {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let dictionary = information as? [String: Any],
          let unique = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
    return unique.map { String(format: "%02x", $0) }.joined()
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
