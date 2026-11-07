// Read-only check of the signing evidence used by HelperIdentity and XPC.
// Does not register/unregister a daemon or change system configuration.
import Foundation
import Security

func check(_ path: String, identifier: String) throws {
    var code: SecStaticCode?
    let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
    guard created == errSecSuccess, let code else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(created)) }
    var information: CFDictionary?
    let copied = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
    guard copied == errSecSuccess, let info = information as? [String: Any],
          info[kSecCodeInfoIdentifier as String] as? String == identifier,
          info[kSecCodeInfoTeamIdentifier as String] == nil else {
        throw NSError(domain: "Maschinery.AdHocCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected ad-hoc code with no Team ID: \(path)"])
    }
    var requirement: SecRequirement?
    let status = SecRequirementCreateWithString("anchor apple generic and identifier \"\(identifier)\"" as CFString, [], &requirement)
    guard status == errSecSuccess, let requirement else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    let validity = SecStaticCodeCheckValidity(code, [], requirement)
    guard validity == errSecCSReqFailed else {
        throw NSError(domain: "Maschinery.AdHocCheck", code: Int(validity), userInfo: [NSLocalizedDescriptionKey: "Expected Apple-anchored trust rejection: \(path)"])
    }
    print("\(identifier): no Team ID; Apple-anchored requirement rejected (\(validity)).")
}
let app = CommandLine.arguments.dropFirst().first ?? "dist/Maschinery.app"
try check(app, identifier: "local.maschinery.app")
try check(app + "/Contents/Library/LaunchServices/MaschineryHelper", identifier: "local.maschinery.helper")
print("The existing team preflight and XPC trust policy cannot authorize this ad-hoc build. Raw SMAppService registration was not invoked or tested.")
