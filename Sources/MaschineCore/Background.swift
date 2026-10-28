import Foundation
/// Runs filesystem work away from the main actor while propagating cancellation.
public func background<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let worker = Task.detached(operation: operation)
    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
}
