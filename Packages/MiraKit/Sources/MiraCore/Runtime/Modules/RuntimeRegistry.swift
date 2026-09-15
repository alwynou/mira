import Foundation

public enum RuntimeRegistryError: Error, Sendable, Equatable {
    case invalidID(String)
    case duplicateID(String)
    case registrationCancelled(String)
    case generationExhausted
}

public struct RuntimeRegistryEntry<Value: Sendable>: Sendable {
    public let id: String
    public let value: Value
    public let scopeID: UUID
    public let scopeKind: RuntimeScopeKind

    public init(id: String, value: Value, scopeID: UUID, scopeKind: RuntimeScopeKind) {
        self.id = id
        self.value = value
        self.scopeID = scopeID
        self.scopeKind = scopeKind
    }
}

/// An immutable turn view. Each entry retains a lease on its declaring scope
/// until the snapshot is explicitly released.
public final class RuntimeRegistrySnapshot<Value: Sendable>: Sendable {
    public let generation: UInt64
    public let entries: [RuntimeRegistryEntry<Value>]

    private let owner: RuntimeRelease

    fileprivate init(generation: UInt64, entries: [RuntimeRegistryEntry<Value>], leases: [RuntimeScopeLease]) {
        self.generation = generation
        self.entries = entries
        owner = RuntimeRelease { for lease in leases { await lease.release() } }
    }

    public func release() async {
        await owner.release()
    }
}

public actor RuntimeRegistry<Value: Sendable> {
    private struct Registration {
        let token: UUID
        let id: String
        let value: Value
        let scopeID: UUID
        let scope: RuntimeScope
        let closingRegistration: UUID
        let order: Int
    }

    private var registrations: [String: Registration] = [:]
    private var pendingIDs: [String: UUID] = [:]
    private var generation: UInt64 = 0

    public init() {}

    public func register(id: String, value: Value, scope: RuntimeScope, order: Int = 0) async throws {
        try Task.checkCancellation()
        guard Self.validID(id) else { throw RuntimeRegistryError.invalidID(id) }
        guard registrations[id] == nil, pendingIDs[id] == nil else {
            throw RuntimeRegistryError.duplicateID(id)
        }
        guard generation < UInt64.max else { throw RuntimeRegistryError.generationExhausted }

        // Reserve before crossing an await so concurrent registrations cannot
        // both pass the duplicate check.
        let token = UUID()
        pendingIDs[id] = token
        var closingRegistration: UUID?
        do {
            closingRegistration = try await scope.registerClosing { [weak self] in
                await self?.removeAfterScopeClose(id: id, token: token)
            }
            // registerClosing either installed the callback or threw because
            // disposal had already begun. No await occurs between that result
            // and publishing the reserved entry.
            guard pendingIDs[id] == token else { throw RuntimeRegistryError.registrationCancelled(id) }
            try Task.checkCancellation()
            guard generation < UInt64.max else { throw RuntimeRegistryError.generationExhausted }
            pendingIDs.removeValue(forKey: id)
            guard let closingRegistration else { throw RuntimeRegistryError.registrationCancelled(id) }
            registrations[id] = Registration(token: token, id: id, value: value, scopeID: scope.id,
                scope: scope, closingRegistration: closingRegistration, order: order)
            generation += 1
        } catch {
            if pendingIDs[id] == token { pendingIDs[id] = nil }
            if let closingRegistration { await scope.unregisterClosing(closingRegistration) }
            throw error
        }
    }

    /// Removes a live entry without invalidating snapshots that already hold
    /// its scope lease.
    public func unregister(id: String) async throws {
        guard registrations[id] != nil || pendingIDs[id] != nil else { return }
        guard generation < UInt64.max else { throw RuntimeRegistryError.generationExhausted }
        let registration = registrations.removeValue(forKey: id)
        // A registration still crossing registerClosing owns withdrawal of its callback in catch.
        pendingIDs.removeValue(forKey: id)
        generation += 1
        if let registration {
            await registration.scope.unregisterClosing(registration.closingRegistration)
        }
    }

    public func freeze() async throws -> RuntimeRegistrySnapshot<Value> {
        try Task.checkCancellation()
        let capturedGeneration = generation
        let captured = registrations.values.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
        }
        var leases: [RuntimeScopeLease] = []
        leases.reserveCapacity(captured.count)

        do {
            for registration in captured {
                try Task.checkCancellation()
                do {
                    // The scope lease is acquired before the value becomes
                    // visible in the returned immutable snapshot.
                    let lease = try await registration.scope.acquireLease()
                    leases.append(lease)
                } catch {
                    throw error
                }
                try Task.checkCancellation()
            }
            let entries = captured.map {
                RuntimeRegistryEntry(id: $0.id, value: $0.value, scopeID: $0.scopeID, scopeKind: $0.scope.kind)
            }
            return RuntimeRegistrySnapshot(generation: capturedGeneration, entries: entries, leases: leases)
        } catch {
            for lease in leases { await lease.release() }
            throw error
        }
    }

    private func removeAfterScopeClose(id: String, token: UUID) {
        if pendingIDs[id] == token { pendingIDs.removeValue(forKey: id) }
        guard registrations[id]?.token == token else { return }
        guard generation < UInt64.max else {
            registrations.removeValue(forKey: id)
            return
        }
        registrations.removeValue(forKey: id)
        generation += 1
    }

    private static func validID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...128).contains(bytes.count), let first = bytes.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first) else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }
}
