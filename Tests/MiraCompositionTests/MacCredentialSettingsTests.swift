import Foundation
import MiraCore
import Testing

@Suite("macOS credential settings", .timeLimit(.minutes(1)))
struct MacCredentialSettingsTests {
    @Test func createsReplacesDeletesAndReopensWithTheSameCredentialStore() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            var surviving: MacConnectionSaveResult?
            do {
                let group = try await library.workloads()
                let configuration = credentialConfiguration()
                let created = try await group.credentialSettings.saveConnection(
                    id: ConnectionID(), name: "Synthetic", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(configuration), discovery: nil, defaultInvocation: nil,
                    previous: nil, credentialEndpointID: "primary", credential: .replace("first-secret"))
                let firstReference = try #require(created.connection.endpoints.first?.credential)
                #expect(
                    try credentials.read(reference: firstReference.reference, version: firstReference.version)
                        == "first-secret")
                #expect(
                    try await group.credentialSettings.credential(for: created.connection, endpointID: "primary") == "first-secret")

                let replaced = try await group.credentialSettings.saveConnection(
                    id: created.connection.id, name: "Renamed", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(configuration), discovery: nil, defaultInvocation: nil,
                    previous: created.connection, credentialEndpointID: "primary", credential: .replace("second-secret"))
                let secondReference = try #require(replaced.connection.endpoints.first?.credential)
                #expect(firstReference != secondReference)
                #expect(
                    try credentials.read(
                        reference: secondReference.reference, version: secondReference.version)
                        == "second-secret")
                #expect(throws: MiraError.self) {
                    _ = try credentials.read(
                        reference: firstReference.reference, version: firstReference.version)
                }

                #expect(
                    try await group.credentialSettings.deleteConnection(replaced.connection) == .complete)
                #expect(throws: MiraError.self) {
                    _ = try credentials.read(
                        reference: secondReference.reference, version: secondReference.version)
                }
                surviving = try await group.credentialSettings.saveConnection(
                    id: ConnectionID(), name: "Survives reopen", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(configuration), discovery: nil, defaultInvocation: nil, previous: nil, credentialEndpointID: "primary", credential: .replace("survivor"))
                #expect(await library.close().isSettled)
            } catch {
                _ = await library.close()
                throw error
            }

            let reopened = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await reopened.workloads()
                #expect(await group.credentialSettings.cleanupStatus() == .complete)
                let surviving = try #require(surviving)
                let survivingReference = try #require(surviving.connection.endpoints.first?.credential)
                #expect(
                    try await group.credentialSettings.credential(for: surviving.connection, endpointID: "primary") == "survivor")
                #expect(
                    try credentials.read(
                        reference: survivingReference.reference, version: survivingReference.version)
                        == "survivor")
                #expect(await reopened.close().isSettled)
            } catch {
                _ = await reopened.close()
                throw error
            }
        }
    }

    @Test func keychainFailureAndSQLConflictRetainCurrentSettingsAndCleanNewReferences() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await library.workloads()
                credentials.failNext(.save)
                await #expect(throws: MiraError.self) {
                    _ = try await group.credentialSettings.saveConnection(
                        id: ConnectionID(), name: "Rejected", isEnabled: true, definitionID: nil,
                        endpoints: credentialEndpoints(credentialConfiguration()), discovery: nil, defaultInvocation: nil, previous: nil, credentialEndpointID: "primary", credential: .replace("failed"))
                }
                #expect(credentials.storedSecrets.isEmpty)

                let created = try await group.credentialSettings.saveConnection(
                    id: ConnectionID(), name: "Current", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(credentialConfiguration()), discovery: nil, defaultInvocation: nil, previous: nil, credentialEndpointID: "primary", credential: .replace("current"))
                let currentReference = try #require(created.connection.endpoints.first?.credential)
                credentials.block(.save)
                let staleSave = Task {
                    try await group.credentialSettings.saveConnection(
                        id: created.connection.id, name: "Stale", isEnabled: true, definitionID: nil,
                        endpoints: credentialEndpoints(credentialConfiguration()), discovery: nil, defaultInvocation: nil, previous: created.connection,
                        credentialEndpointID: "primary", credential: .replace("orphan"))
                }
                try await eventually { credentials.enteredOperations.contains(.save) }
                // Both candidate references are durable before the blocked Keychain write proceeds.
                let pending = try Data(contentsOf: directory.appendingPathComponent("credential-cleanup.json"))
                let ledger = try #require(JSONSerialization.jsonObject(with: pending) as? [String: Any])
                #expect((ledger["items"] as? [[String: Any]])?.count == 2)
                #expect(!String(decoding: pending, as: UTF8.self).contains("orphan"))
                let external = created.connection.copy(revision: 2, name: "External")
                // Fault injection only: bypass the ordinary host boundary to create a concurrent SQL CAS race.
                let underlying = try #require(group.modelSettings as? AgentModelSettingsApplication)
                try await underlying.saveConnection(external, expectedRevision: 1)
                credentials.release(.save)
                await #expect(throws: MiraError.self) { _ = try await staleSave.value }
                #expect(try await group.modelSettings.connection(id: created.connection.id) == external)
                #expect(credentials.storedSecrets.count == 1)
                #expect(
                    try credentials.read(
                        reference: currentReference.reference, version: currentReference.version) == "current")
                #expect(await library.close().isSettled)
            } catch {
                credentials.release(.save)
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func credentialsRemainScopedToTheSelectedEndpoint() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await library.workloads()
                let configuration = credentialConfiguration()
                let created = try await group.credentialSettings.saveConnection(
                    id: ConnectionID(), name: "Multi-endpoint", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(configuration, includeSecondary: true),
                    discovery: nil, defaultInvocation: nil, previous: nil,
                    credentialEndpointID: "primary", credential: .replace("primary-secret"))
                let primary = try #require(created.connection.endpoint(id: "primary").credential)
                #expect(try await group.credentialSettings.credential(
                    for: created.connection, endpointID: "primary") == "primary-secret")
                #expect(try await group.credentialSettings.credential(
                    for: created.connection, endpointID: "secondary") == nil)

                let withSecondary = try await group.credentialSettings.saveConnection(
                    id: created.connection.id, name: created.connection.name, isEnabled: true, definitionID: nil,
                    endpoints: created.connection.endpoints, discovery: nil, defaultInvocation: nil,
                    previous: created.connection, credentialEndpointID: "secondary",
                    credential: .replace("secondary-secret"))
                let secondary = try #require(withSecondary.connection.endpoint(id: "secondary").credential)
                let replacement = try await group.credentialSettings.saveConnection(
                    id: created.connection.id, name: created.connection.name, isEnabled: true, definitionID: nil,
                    endpoints: withSecondary.connection.endpoints, discovery: nil, defaultInvocation: nil,
                    previous: withSecondary.connection, credentialEndpointID: "primary",
                    credential: .replace("replacement-secret"))
                let replacementPrimary = try #require(replacement.connection.endpoint(id: "primary").credential)
                #expect(replacementPrimary != primary)
                #expect(try await group.credentialSettings.credential(
                    for: replacement.connection, endpointID: "primary") == "replacement-secret")
                #expect(try await group.credentialSettings.credential(
                    for: replacement.connection, endpointID: "secondary") == "secondary-secret")
                #expect(try replacement.connection.endpoint(id: "secondary").credential == secondary)
                #expect(credentials.storedSecrets.count == 2)

                let attemptedCrossEndpointReference = AgentCredentialReference(
                    reference: "synthetic.cross-endpoint", version: 1)
                let contaminated = replacement.connection.endpoints.map { endpoint in
                    endpoint.id == "secondary"
                        ? AgentModelEndpoint(id: endpoint.id, configuration: endpoint.configuration,
                                             credential: attemptedCrossEndpointReference)
                        : endpoint
                }
                await #expect(throws: MiraError.self) {
                    _ = try await group.credentialSettings.saveConnection(
                        id: created.connection.id, name: created.connection.name, isEnabled: true, definitionID: nil,
                        endpoints: contaminated, discovery: nil, defaultInvocation: nil,
                        previous: replacement.connection, credentialEndpointID: "primary", credential: .keep)
                }
                #expect(try await group.modelSettings.connection(id: created.connection.id) == replacement.connection)
                let renamed = try await group.credentialSettings.saveConnection(
                    id: created.connection.id, name: "Renamed endpoints", isEnabled: true, definitionID: nil,
                    endpoints: replacement.connection.endpoints, discovery: nil, defaultInvocation: nil,
                    previous: replacement.connection, credentialEndpointID: "primary", credential: .keep)
                #expect(renamed.connection.revision == replacement.connection.revision + 1)
                #expect(renamed.connection.configurationRevision == replacement.connection.configurationRevision)
                #expect(renamed.connection.endpoints == replacement.connection.endpoints)
                #expect(await library.close().isSettled)
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func cleanupFailureIsReportedAndRetryRemovesOnlyUnretainedCredentials() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await library.workloads()
                let configuration = credentialConfiguration()
                let created = try await group.credentialSettings.saveConnection(
                    id: ConnectionID(), name: "Current", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(configuration), discovery: nil, defaultInvocation: nil,
                    previous: nil, credentialEndpointID: "primary", credential: .replace("old"))
                let old = try #require(created.connection.endpoints.first?.credential)
                credentials.failNext(.delete)
                let replaced = try await group.credentialSettings.saveConnection(
                    id: created.connection.id, name: "Current", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(configuration), discovery: nil, defaultInvocation: nil,
                    previous: created.connection, credentialEndpointID: "primary", credential: .replace("new"))
                let new = try #require(replaced.connection.endpoints.first?.credential)
                if case .pending = await group.credentialSettings.cleanupStatus() {
                } else {
                    Issue.record("Expected failed Keychain cleanup to remain pending.")
                }
                #expect(credentials.storedSecrets.count == 2)

                #expect(try await group.credentialSettings.retryCleanup() == .complete)
                #expect(credentials.storedSecrets.count == 1)
                #expect(throws: MiraError.self) {
                    _ = try credentials.read(reference: old.reference, version: old.version)
                }
                #expect(try credentials.read(reference: new.reference, version: new.version) == "new")
                #expect(await library.close().isSettled)
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func pendingCleanupSurvivesCloseAndIsRetriedOnReopen() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            var oldReference: AgentCredentialReference?
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await library.workloads()
                let configuration = credentialConfiguration()
                let created = try await group.credentialSettings.saveConnection(
                    id: ConnectionID(), name: "Current", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(configuration), discovery: nil, defaultInvocation: nil,
                    previous: nil, credentialEndpointID: "primary", credential: .replace("old"))
                oldReference = created.connection.endpoints.first?.credential
                credentials.failNext(.delete)
                let replaced = try await group.credentialSettings.saveConnection(
                    id: created.connection.id, name: "Current", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(configuration), discovery: nil, defaultInvocation: nil,
                    previous: created.connection, credentialEndpointID: "primary", credential: .replace("new"))
                #expect(replaced.cleanup != .complete)
                #expect(credentials.storedSecrets.count == 2)
                #expect(await library.close().isSettled)
            } catch {
                _ = await library.close()
                throw error
            }

            let reopened = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await reopened.workloads()
                #expect(await group.credentialSettings.cleanupStatus() == .complete)
                #expect(credentials.storedSecrets.count == 1)
                let oldReference = try #require(oldReference)
                #expect(throws: MiraError.self) {
                    _ = try credentials.read(reference: oldReference.reference, version: oldReference.version)
                }
                #expect(await reopened.close().isSettled)
            } catch {
                _ = await reopened.close()
                throw error
            }
        }
    }

    @Test func callerCancellationDoesNotDiscardAnAcceptedSave() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await library.workloads()
                let configuration = credentialConfiguration()
                credentials.block(.save)
                let save = Task {
                    try await group.credentialSettings.saveConnection(
                        id: ConnectionID(), name: "Accepted", isEnabled: true, definitionID: nil,
                        endpoints: credentialEndpoints(configuration), discovery: nil, defaultInvocation: nil,
                        previous: nil, credentialEndpointID: "primary", credential: .replace("blocked"))
                }
                try await eventually { credentials.enteredOperations.contains(.save) }
                await #expect(throws: MiraError.self) { _ = try await group.credentialSettings.retryCleanup() }
                save.cancel()
                credentials.release(.save)
                let saved = try await save.value
                #expect(
                    try await group.modelSettings.connection(id: saved.connection.id) == saved.connection)
                #expect(await library.close().isSettled)
            } catch {
                credentials.release(.save)
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func closeDrainsANonCooperativeSave() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await library.workloads()
                credentials.block(.save)
                let save = Task {
                    try await group.credentialSettings.saveConnection(
                        id: ConnectionID(), name: "Closing", isEnabled: true, definitionID: nil,
                        endpoints: credentialEndpoints(credentialConfiguration()), discovery: nil, defaultInvocation: nil, previous: nil,
                        credentialEndpointID: "primary", credential: .replace("closing"))
                }
                try await eventually { credentials.enteredOperations.contains(.save) }
                let closed = CloseProbe()
                let closing = Task {
                    await group.credentialSettings.close()
                    await closed.mark()
                }
                try await Task.sleep(for: .milliseconds(20))
                #expect(!(await closed.value))
                credentials.release(.save)
                _ = await save.result
                await closing.value
                #expect(await library.close().isSettled)
            } catch {
                credentials.release(.save)
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func cancelledReadAndCloseWaitForNonCooperativeCredentialCall() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await library.workloads()
                let saved = try await group.credentialSettings.saveConnection(
                    id: ConnectionID(), name: "Readable", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(credentialConfiguration()), discovery: nil, defaultInvocation: nil, previous: nil, credentialEndpointID: "primary", credential: .replace("readable"))
                credentials.block(.read)
                let read = Task {
                    try await group.credentialSettings.credential(for: saved.connection, endpointID: "primary")
                }
                try await eventually { credentials.enteredOperations.contains(.read) }
                read.cancel()
                let closed = CloseProbe()
                let closing = Task {
                    await group.credentialSettings.close()
                    await closed.mark()
                }
                try await Task.sleep(for: .milliseconds(20))
                #expect(!(await closed.value))
                credentials.release(.read)
                await #expect(throws: Error.self) { _ = try await read.value }
                await closing.value
                #expect(await library.close().isSettled)
            } catch {
                credentials.release(.read)
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func maintenanceWaitsForKeychainAndNewWorkGroupReconcilesAbandonedReference() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { _ in [] })
            do {
                let group = try await library.workloads()
                let current = try await group.credentialSettings.saveConnection(
                    id: ConnectionID(), name: "Current", isEnabled: true, definitionID: nil,
                    endpoints: credentialEndpoints(credentialConfiguration()), discovery: nil, defaultInvocation: nil, previous: nil, credentialEndpointID: "primary", credential: .replace("retained"))
                credentials.block(.save)
                let replacement = Task {
                    try await group.credentialSettings.saveConnection(
                        id: current.connection.id, name: "Replacement", isEnabled: true, definitionID: nil,
                        endpoints: current.connection.endpoints, discovery: current.connection.discovery,
                        defaultInvocation: current.connection.defaultInvocation, previous: current.connection,
                        credentialEndpointID: "primary", credential: .replace("abandoned"))
                }
                try await eventually { credentials.enteredOperations.contains(.save) }
                let completed = CloseProbe()
                let maintenance = Task {
                    let result = try await library.maintain(
                        .init(
                            id: UUID(), namespace: "knowledge.collect", revision: 1,
                            scope: .library, requestedAt: Date()))
                    await completed.mark()
                    return result
                }
                // A revoked ordinary query proves the maintenance gate has stopped new access.
                try await eventually {
                    do {
                        _ = try await group.modelSettings.connections(after: nil, limit: 128)
                        return false
                    } catch { return true }
                }
                #expect(!(await completed.value))
                credentials.release(.save)
                await #expect(throws: Error.self) { _ = try await replacement.value }
                #expect(try await maintenance.value.completedAt != nil)
                let fresh = try await library.workloads()
                #expect(try await fresh.modelSettings.connection(id: current.connection.id) == current.connection)
                #expect(try await fresh.credentialSettings.credential(for: current.connection, endpointID: "primary") == "retained")
                #expect(await fresh.credentialSettings.cleanupStatus() == .complete)
                #expect(credentials.storedSecrets.count == 1)
                #expect(
                    !FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("credential-cleanup.json").path))
                #expect(await library.close().isSettled)
            } catch {
                credentials.release(.save)
                _ = await library.close()
                throw error
            }
        }
    }
}

private func credentialConfiguration() -> AgentConfigurationValue {
    .init(schema: .init(id: "tests.credentials", revision: 1), value: .object([:]))
}

private func credentialEndpoints(_ configuration: AgentConfigurationValue, includeSecondary: Bool = false) -> [AgentModelEndpoint] {
    var endpoints = [AgentModelEndpoint(id: "primary", configuration: configuration, credential: nil)]
    if includeSecondary {
        endpoints.append(.init(id: "secondary", configuration: configuration, credential: nil))
    }
    return endpoints
}

extension AgentConfiguredConnection {
    fileprivate func copy(revision: Int, name: String) -> Self {
        .init(
            id: id, revision: revision, configurationRevision: configurationRevision,
            name: name, isEnabled: isEnabled, definitionID: definitionID, endpoints: endpoints,
            discovery: discovery, defaultInvocation: defaultInvocation)
    }
}

private actor CloseProbe {
    private(set) var value = false
    func mark() { value = true }
}
