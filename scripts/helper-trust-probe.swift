// Compiled and ad-hoc signed by test-helper-trust.sh. Exercises real NSXPC peer checks.
import Foundation
import Security

@objc protocol ProbeProtocol { func ping(reply: @escaping (String) -> Void) }
final class Server: NSObject, NSXPCListenerDelegate, ProbeProtocol, @unchecked Sendable {
    let requirement: String
    init(_ requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ProbeProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func ping(reply: @escaping (String) -> Void) { reply("accepted") }
}
final class Outcome: @unchecked Sendable {
    let lock = NSLock()
    var result: Bool?
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; if result == nil { result = value } }
    func read() -> Bool? { lock.lock(); defer { lock.unlock() }; return result }
}
func probe(client: String, server: String, expectSuccess: Bool) -> Bool {
    let delegate = Server(server)
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate; listener.resume()
    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    let outcome = Outcome()
    connection.remoteObjectInterface = NSXPCInterface(with: ProbeProtocol.self)
    connection.setCodeSigningRequirement(client)
    connection.invalidationHandler = { outcome.set(false) }
    connection.resume()
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in outcome.set(false) } as! ProbeProtocol
    proxy.ping { outcome.set($0 == "accepted") }
    let deadline = Date().addingTimeInterval(8)
    while outcome.read() == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    connection.invalidate(); listener.invalidate()
    withExtendedLifetime(delegate) {}
    return outcome.read() == expectSuccess
}
let hash = CommandLine.arguments[1]
let valid = "identifier \"local.maschinery.app\" and cdhash H\"\(hash)\""
let invalid = "identifier \"local.maschinery.app\" and cdhash H\"\(String(repeating: "0", count: 40))\""
guard probe(client: valid, server: valid, expectSuccess: true),
      probe(client: invalid, server: valid, expectSuccess: false),
      probe(client: valid, server: invalid, expectSuccess: false) else {
    fputs("NSXPC hash authentication probe failed\n", stderr); exit(1)
}
print("NSXPC accepted matching ad-hoc hashes and rejected both mismatched peers.")
