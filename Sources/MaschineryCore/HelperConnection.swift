import Foundation
import Security
import ServiceManagement

public enum HelperIdentity {
    public static let app = "local.maschinery.app"
    public static let setup = "local.maschinery.setup"
    public static let service = "local.maschinery.helper"
    public static let plist = service + ".plist"
    public static func team() throws -> String {
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { throw MaschineryError.unavailable("Install the Full Install .pkg to authorize the helper without an Apple certificate. Apple-signed development builds must use the same team for the app and helper.") }
        return team
    }
    public static func requirement(identifier: String) throws -> String {
        if InstalledHelperTrust.isPresent { return try InstalledHelperTrust.load().requirement(identifier: identifier) }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(try team())\""
    }
}
@objc public protocol RegistrationXPC {
    func perform(_ data: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}
public struct HelperMessage: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case ping, apply, verify, finish, rollback, phase, swapShared, restoreShared, cleanupShared, repairPermissions, verifyPermissions }
    public let action: Action
    public let transaction: UUID
    public let registration: RegistrationRequest?
    public let sharedContent: SharedContentRequest?
    public let permissions: PermissionRepairRequest?
    public init(_ action: Action, transaction: UUID = UUID(), registration: RegistrationRequest? = nil, sharedContent: SharedContentRequest? = nil, permissions: PermissionRepairRequest? = nil) { self.action = action; self.transaction = transaction; self.registration = registration; self.sharedContent = sharedContent; self.permissions = permissions }
}
public struct HelperResponse: Codable, Sendable {
    public let phase: RegistrationPhase
    public let supportsPermissionRepair: Bool?
    public init(phase: RegistrationPhase, supportsPermissionRepair: Bool = true) { self.phase = phase; self.supportsPermissionRepair = supportsPermissionRepair }
}
public struct XPCPrivilegedService: PrivilegedService {
    public init() {}
    public static var status: SMAppService.Status {
        if InstalledHelperTrust.isPresent {
            do { try InstalledHelperTrust.load().validateCurrentApp(); return .enabled }
            catch { return .notFound }
        }
        return SMAppService.daemon(plistName: HelperIdentity.plist).status
    }
    public static func enable() throws {
        if InstalledHelperTrust.isPresent {
            try InstalledHelperTrust.load().validateCurrentApp()
            return
        }
        guard (try? HelperIdentity.team()) != nil else {
            throw MaschineryError.unavailable("Install Maschinery using its Full Install .pkg, then reopen it from Applications. The installer asks for administrator approval and sets up the helper without an Apple developer certificate.")
        }
        if status == .enabled || status == .requiresApproval { return }
        try SMAppService.daemon(plistName: HelperIdentity.plist).register()
    }
    public static func unregisterLegacyHelper() throws {
        guard !InstalledHelperTrust.isPresent else {
            throw MaschineryError.unavailable("Quit Maschinery and open the Remove Helper .pkg to remove the installed helper. Your libraries and recovery journals are retained.")
        }
        try SMAppService.daemon(plistName: HelperIdentity.plist).unregister()
    }
    public func preflight() async throws {
        if InstalledHelperTrust.isPresent { try InstalledHelperTrust.load().validateCurrentApp() }
        else { _ = try HelperIdentity.team() }
        guard Self.status == .enabled else { throw MaschineryError.unavailable("Install the matching Full Install .pkg, or enable the Apple-signed helper in Settings.") }
        _ = try await send(HelperMessage(.ping))
    }
    public func repairPermissions(_ request: PermissionRepairRequest) async throws {
        let capabilities = try await send(HelperMessage(.ping))
        guard capabilities.supportsPermissionRepair == true else {
            throw MaschineryError.unavailable("The running helper predates independent permission repair. Replace your installed app with this updated build, quit Maschinery, turn its background item off and on in System Settings, then reopen. No permissions or registration were changed.")
        }
        _ = try await send(HelperMessage(.repairPermissions, transaction: request.transaction, permissions: request))
    }
    public func verifyPermissions(_ request: PermissionRepairRequest) async throws { _ = try await send(HelperMessage(.verifyPermissions, transaction: request.transaction, permissions: request)) }
    public func apply(_ request: RegistrationRequest) async throws { _ = try await send(HelperMessage(.apply, transaction: request.transaction, registration: request)) }
    public func verify(_ request: RegistrationRequest) async throws { _ = try await send(HelperMessage(.verify, transaction: request.transaction, registration: request)) }
    public func finish(_ transaction: UUID) async throws { _ = try await send(HelperMessage(.finish, transaction: transaction)) }
    public func rollback(_ transaction: UUID) async throws { _ = try await send(HelperMessage(.rollback, transaction: transaction)) }
    public func phase(_ transaction: UUID) async throws -> RegistrationPhase { try await send(HelperMessage(.phase, transaction: transaction)).phase }
    public func swapShared(_ request: SharedContentRequest) async throws { _ = try await send(HelperMessage(.swapShared, transaction: request.transaction, sharedContent: request)) }
    public func restoreShared(_ request: SharedContentRequest) async throws { _ = try await send(HelperMessage(.restoreShared, transaction: request.transaction, sharedContent: request)) }
    public func cleanupShared(_ request: SharedContentRequest) async throws { _ = try await send(HelperMessage(.cleanupShared, transaction: request.transaction, sharedContent: request)) }
    /// The root installer can only ping; it cannot perform library operations.
    public func installationHealthCheck() async throws {
        guard geteuid() == 0 else { throw MaschineryError.invalid("Installer health check requires root") }
        try InstalledHelperTrust.load().validateCurrentExecutable(identifier: HelperIdentity.setup)
        _ = try await send(HelperMessage(.ping), timeout: 10)
    }
    private func send(_ message: HelperMessage, timeout: Double = 120) async throws -> HelperResponse {
        let connection = NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: RegistrationXPC.self)
        connection.setCodeSigningRequirement(try HelperIdentity.requirement(identifier: HelperIdentity.service))
        connection.resume()
        let data = try JSONEncoder().encode(message)
        return try await withCheckedThrowingContinuation { continuation in
            let completion = XPCCompletion(connection: connection, continuation: continuation)
            connection.invalidationHandler = { completion.resolve(.failure(MaschineryError.unavailable("Helper connection was interrupted. The transaction is retained for recovery."))) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in completion.resolve(.failure(error)) }) as? RegistrationXPC else { completion.resolve(.failure(MaschineryError.unavailable("Helper proxy unavailable"))); return }
            proxy.perform(data) { data, error in
                if let error { completion.resolve(.failure(MaschineryError.invalid(error))) }
                else if let data { do { completion.resolve(.success(try JSONDecoder().decode(HelperResponse.self, from: data))) } catch { completion.resolve(.failure(error)) } }
                else { completion.resolve(.failure(MaschineryError.invalid("Empty helper response"))) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { completion.resolve(.failure(MaschineryError.unavailable("Helper timed out. Recovery will check the durable transaction before making further changes."))) }
        }
    }
}
private final class XPCCompletion: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<HelperResponse, Error>?
    let connection: NSXPCConnection
    init(connection: NSXPCConnection, continuation: CheckedContinuation<HelperResponse, Error>) { self.connection = connection; self.continuation = continuation }
    func resolve(_ result: Result<HelperResponse, Error>) {
        lock.lock(); let saved = continuation; continuation = nil; lock.unlock()
        guard let saved else { return }; connection.invalidationHandler = nil; saved.resume(with: result); connection.invalidate()
    }
}
