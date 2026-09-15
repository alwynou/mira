import Foundation
import MiraCore

enum MacCredentialChange: Sendable {
    case keep
    case replace(String)
    case remove
}

enum MacCredentialCleanupStatus: Sendable, Equatable {
    case complete
    case pending(MiraError)
}

struct MacConnectionSaveResult: Sendable {
    let connection: AgentConfiguredConnection
    let cleanup: MacCredentialCleanupStatus
}

/// The only host writer of credential references. Serial ownership prevents a
/// cleanup snapshot from racing another host command that adopts a reference.
actor MacCredentialSettings {
    private let settings: AgentModelSettingsApplication
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let credentials: any MacCredentialStore
    private let cleanup: CredentialCleanup
    private var operationDrain: (@Sendable () async -> Void)?
    private var closed = false
    private var closeTask: Task<Void, Never>?
    private var cleanupState: MacCredentialCleanupStatus = .complete

    init(
        settings: AgentModelSettingsApplication, access: AgentLibraryAccess, scope: RuntimeScope,
        directory: URL, credentials: any MacCredentialStore
    ) {
        self.settings = settings
        self.access = access
        self.scope = scope
        self.credentials = credentials
        cleanup = CredentialCleanup(directory: directory, libraryID: access.libraryID)
    }

    func cleanupStatus() -> MacCredentialCleanupStatus { cleanupState }

    /// Cleanup failure does not prevent unrelated session recovery or library use.
    func start() async {
        do { _ = try await retryCleanup() } catch { cleanupState = .pending(MiraError.safe(error)) }
    }

    func credential(for connection: AgentConfiguredConnection, endpointID: String) async throws -> String? {
        try await owned(cancelWithCaller: true) { lease in
            try await lease.read {
                guard try await self.settings.connection(id: connection.id) == connection else {
                    throw Self.conflict
                }
                guard let reference = try connection.endpoint(id: endpointID).credential else { return nil }
                let secret = try self.credentials.read(reference: reference.reference, version: reference.version)
                guard try await self.settings.connection(id: connection.id) == connection else {
                    throw Self.conflict
                }
                return secret
            }
        }
    }

    func saveConnection(
        id: ConnectionID, name: String, isEnabled: Bool, definitionID: String?,
        endpoints: [AgentModelEndpoint], discovery: AgentConnectionDiscovery?,
        defaultInvocation: AgentModelInvocationTemplate?, previous: AgentConfiguredConnection?,
        credentialEndpointID: String, credential: MacCredentialChange
    ) async throws -> MacConnectionSaveResult {
        try await owned(cancelWithCaller: false) { lease in
            guard previous?.id == id || previous == nil,
                try await self.settings.connection(id: id) == previous
            else { throw Self.conflict }
            guard (previous?.revision ?? 0) < Int.max,
                  endpoints.contains(where: { $0.id == credentialEndpointID }) else { throw Self.conflict }
            // Unedited endpoints cannot adopt references from another endpoint or connection.
            for endpoint in endpoints where endpoint.id != credentialEndpointID {
                guard endpoint.credential == previous?.endpoints.first(where: { $0.id == endpoint.id })?.credential else {
                    throw Self.conflict
                }
            }
            let reference: AgentCredentialReference?
            let previousReference = previous?.endpoints.first(where: { $0.id == credentialEndpointID })?.credential
            switch credential {
            case .keep: reference = previousReference
            case .remove: reference = nil
            case .replace(let secret):
                guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    (previousReference?.version ?? 0) < Int.max
                else { throw MiraError(.credentialMissing, "Enter an API key.") }
                reference = self.cleanup.makeReference(version: (previousReference?.version ?? 0) + 1)
            }
            let storedEndpoints = endpoints.map { endpoint in
                endpoint.id == credentialEndpointID
                    ? AgentModelEndpoint(id: endpoint.id, configuration: endpoint.configuration, credential: reference)
                    : endpoint
            }
            let authorizationChanged = previous.map {
                $0.isEnabled != isEnabled || $0.endpoints != storedEndpoints
            } ?? true
            guard !authorizationChanged || (previous?.configurationRevision ?? 0) < Int.max else { throw Self.conflict }
            let value = AgentConfiguredConnection(
                id: id, revision: (previous?.revision ?? 0) + 1,
                configurationRevision: (previous?.configurationRevision ?? 0) + (authorizationChanged ? 1 : 0),
                name: name, isEnabled: isEnabled, definitionID: definitionID,
                endpoints: storedEndpoints, discovery: discovery, defaultInvocation: defaultInvocation)
            try value.validate()
            try await lease.check()
            // The ledger reaches its durability barrier before any new Keychain item.
            let oldReferences = previous?.endpoints.compactMap(\.credential) ?? []
            let newReferences = storedEndpoints.compactMap(\.credential)
            if oldReferences != newReferences {
                try self.cleanup.enqueue(oldReferences + newReferences)
            }
            do {
                if case .replace(let secret) = credential, let reference {
                    try self.credentials.save(secret, reference: reference.reference, version: reference.version)
                }
                try await lease.check()
                try await self.settings.saveConnection(value, expectedRevision: previous?.revision)
            } catch {
                // Consult current settings before deleting anything. A storage error
                // alone is never evidence that the new reference was not committed.
                _ = await self.reconcile(lease)
                throw error
            }
            return MacConnectionSaveResult(connection: value, cleanup: await self.reconcile(lease))
        }
    }

    func deleteConnection(_ connection: AgentConfiguredConnection) async throws -> MacCredentialCleanupStatus {
        try await owned(cancelWithCaller: false) { lease in
            guard try await self.settings.connection(id: connection.id) == connection else { throw Self.conflict }
            try await lease.check()
            try self.cleanup.enqueue(connection.endpoints.compactMap(\.credential))
            do {
                try await lease.check()
                try await self.settings.deleteConnection(id: connection.id, expectedRevision: connection.revision)
            } catch {
                _ = await self.reconcile(lease)
                throw error
            }
            return await self.reconcile(lease)
        }
    }

    func retryCleanup() async throws -> MacCredentialCleanupStatus {
        try await owned(cancelWithCaller: false) { lease in await self.reconcile(lease) }
    }

    func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        closed = true
        let drain = operationDrain
        let task = Task<Void, Never> { await drain?() }
        closeTask = task
        await task.value
    }

    private nonisolated func reconcile(_ lease: AgentLibraryAccessLease) async -> MacCredentialCleanupStatus {
        let status: MacCredentialCleanupStatus
        do {
            // The store caps the entire connection collection at 128. This one
            // read is the complete current reference set, not a partial scan.
            let connections = try await settings.connections(after: nil, limit: 128)
            try await lease.check()
            let pending = try cleanup.reconcile(
                retaining: connections.flatMap { $0.endpoints.compactMap(\.credential) }, credentials: credentials)
            status = pending ? .pending(Self.cleanupPending) : .complete
        } catch {
            status = .pending(MiraError.safe(error))
        }
        await setCleanupStatus(status)
        return status
    }

    private func setCleanupStatus(_ status: MacCredentialCleanupStatus) { cleanupState = status }

    private func owned<T: Sendable>(
        cancelWithCaller: Bool,
        _ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.busy, "The credential settings service is closed.") }
        guard operationDrain == nil else { throw MiraError(.busy, "Another credential settings operation is active.") }
        let task = Task {
            defer { self.operationDrain = nil }
            return try await self.perform(operation)
        }
        operationDrain = {
            task.cancel()
            _ = await task.result
        }
        if cancelWithCaller {
            return try await withTaskCancellationHandler {
                let value = try await task.value
                try Task.checkCancellation()
                return value
            } onCancel: {
                task.cancel()
            }
        }
        return try await task.value
    }

    private nonisolated func perform<T: Sendable>(
        _ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T
    ) async throws -> T {
        let lease = try await access.acquire(in: scope)
        let resource: AgentLibraryResourceLease<Task<T, any Error>>
        do {
            resource = try await lease.start {
                let task = Task { try await operation(lease) }
                return AgentLibraryResource(
                    value: task,
                    cleanup: {
                        task.cancel()
                        _ = await task.result
                    })
            }
        } catch {
            await lease.release()
            throw error
        }
        do {
            try lease.bindCancellation { resource.value.cancel() }
            let result = try await withTaskCancellationHandler {
                try await resource.value.value
            } onCancel: {
                resource.value.cancel()
            }
            await resource.release()
            await lease.release()
            return result
        } catch {
            await resource.release()
            await lease.release()
            throw error
        }
    }

    private nonisolated static var conflict: MiraError {
        .init(.conflict, "The provider configuration changed. Discard your draft and try again.")
    }
    private nonisolated static var cleanupPending: MiraError {
        .init(
            .credentialMissing,
            "Connection changes were saved. Some old Keychain credentials could not be removed and were queued for retry. Retry cleanup in Data settings."
        )
    }
}
