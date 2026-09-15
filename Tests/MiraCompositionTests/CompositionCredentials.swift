import Foundation
import MiraCore

/// A process-local Keychain substitute shared by all composition fixtures.
/// The lock keeps synchronous platform calls deterministic while optional
/// semaphores make cancellation and close tests exercise real non-cooperative
/// calls.
final class CompositionCredentials: MacCredentialStore, @unchecked Sendable {
    enum Operation: Hashable, Sendable {
        case read
        case save
        case delete
    }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failures: [Operation: Error] = [:]
    private var gates: [Operation: DispatchSemaphore] = [:]
    private var entered: Set<Operation> = []

    func read(reference: String, version: Int) throws -> String {
        try begin(.read)
        let key = Self.key(reference: reference, version: version)
        guard let value = lock.withLock({ values[key] }) else {
            throw MiraError(.credentialMissing, "Synthetic credentials are unavailable.")
        }
        return value
    }

    func save(_ secret: String, reference: String, version: Int) throws {
        try begin(.save)
        let key = Self.key(reference: reference, version: version)
        lock.withLock { values[key] = secret }
    }

    func delete(reference: String, version: Int) throws {
        try begin(.delete)
        let key = Self.key(reference: reference, version: version)
        lock.withLock { values[key] = nil }
    }

    func block(_ operation: Operation) {
        lock.withLock {
            gates[operation] = DispatchSemaphore(value: 0)
            entered.remove(operation)
        }
    }

    func release(_ operation: Operation) {
        let gate = lock.withLock { gates.removeValue(forKey: operation) }
        gate?.signal()
    }

    func failNext(
        _ operation: Operation,
        error: Error = MiraError(.credentialMissing, "Synthetic Keychain failure.")
    ) {
        lock.withLock { failures[operation] = error }
    }

    var enteredOperations: Set<Operation> { lock.withLock { entered } }

    var storedSecrets: [String: String] { lock.withLock { values } }

    private func begin(_ operation: Operation) throws {
        let (gate, failure): (DispatchSemaphore?, Error?) = lock.withLock {
            entered.insert(operation)
            return (gates[operation], failures.removeValue(forKey: operation))
        }
        gate?.wait()
        if let failure { throw failure }
    }

    private static func key(reference: String, version: Int) -> String {
        "\(reference):\(version)"
    }
}
