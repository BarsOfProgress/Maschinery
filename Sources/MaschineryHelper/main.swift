import Foundation
import MaschineryCore
import Darwin

final class Helper: NSObject, NSXPCListenerDelegate, RegistrationXPC, @unchecked Sendable {
    let engine = RegistrationEngine(locations: .system)
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let identifier = connection.effectiveUserIdentifier == 0 ? HelperIdentity.setup : HelperIdentity.app
        if connection.effectiveUserIdentifier == 0 && !InstalledHelperTrust.isPresent { return false }
        guard let requirement = try? HelperIdentity.requirement(identifier: identifier) else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: RegistrationXPC.self)
        connection.exportedObject = self
        connection.resume(); return true
    }
    func perform(_ data: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard data.count <= 70 * 1024 * 1024 else { reply(nil, "Helper request exceeds limit"); return }
        guard let user = NSXPCConnection.current()?.effectiveUserIdentifier else { reply(nil, "Missing user identity"); return }
        Task {
            do {
                let message = try JSONDecoder().decode(HelperMessage.self, from: data)
                if user == 0 {
                    guard message.action == .ping, message.registration == nil, message.sharedContent == nil, message.permissions == nil else {
                        throw MaschineryError.invalid("The installer may only check helper health")
                    }
                    try await engine.preflight()
                    reply(try JSONEncoder().encode(HelperResponse(phase: .absent)), nil)
                    return
                }
                try await engine.authorizePermissionTransaction(message.transaction, user: user)
                switch message.action {
                case .repairPermissions, .verifyPermissions:
                    guard let request = message.permissions, request.transaction == message.transaction, message.registration == nil, message.sharedContent == nil else { throw MaschineryError.invalid("Missing or mismatched permission repair request") }
                    if message.action == .repairPermissions { try await engine.applyPermissionRepair(request, user: user) }
                    else { try await engine.verifyPermissions(request) }
                case .ping: try await engine.preflight()
                case .apply, .verify:
                    guard let request = message.registration, request.transaction == message.transaction else { throw MaschineryError.invalid("Missing or mismatched registration request") }
                    if message.action == .apply { try await engine.apply(request) } else { try await engine.verify(request) }
                case .finish: try await engine.finish(message.transaction)
                case .rollback: try await engine.rollback(message.transaction)
                case .swapShared, .restoreShared, .cleanupShared:
                    guard let request = message.sharedContent, request.transaction == message.transaction else { throw MaschineryError.invalid("Missing shared content request") }
                    try await engine.sharedOperation(message.action, request: request, user: user)
                case .phase: break
                }
                let response = HelperResponse(phase: try await engine.phase(message.transaction))
                reply(try JSONEncoder().encode(response), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
}
guard geteuid() == 0 else { fputs("MaschineryHelper must be launched by its approved launch daemon.\n", stderr); exit(1) }
let delegate = Helper()
let listener = NSXPCListener(machServiceName: HelperIdentity.service)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
