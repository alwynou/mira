import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Production context and source authorization")
struct AgentSourceAuthorityTests {
    @Test func emptySourceSelectionStillChecksDestinationWhileLocalAccessRemainsLocal() async throws {
        try await withTaskWorkflow { f in
            let workspace = Workspace(id: .init(), name: "Local only", allowsRemoteSend: false)
            try await save(workspace, in: f)
            try await f.authorizer.validate([], for: request(f, workspaceID: workspace.id, destination: .local))
            await #expect(throws: MiraError.self) {
                try await f.authorizer.validate([], for: request(f, workspaceID: workspace.id))
            }
            #expect(await f.model.inputs.isEmpty)
        }
    }

    @Test func textOnlyRoutesDoNotRequireToolCapability() async throws {
        try await withTaskWorkflow { f in
            let model = try #require(try await f.settings.model(id: f.route.modelDescriptorID))
            try await f.settings.saveModel(.init(id: model.id, revision: model.revision + 1, authorizationRevision: 1, reference: .init(connectionID: model.connectionID, modelID: model.modelID), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: model.invocations[0].adapter, endpointID: "primary", contextWindow: model.invocations[0].contextWindow, maximumOutputTokens: nil, capabilities: [AgentModelCapabilityID.streamingText: .declared], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: []), expectedRevision: model.revision, authorization: f.authority.authorization())
            let route = try await f.settings.candidate(routeID: f.route.id).freeze(configuration: f.route.configuration)
            #expect(!route.capabilities.callsTools)
            try await f.authorizer.validate([], for: request(f, destination: .model(route)))
            try await f.authorizer.validate([], for: request(f))
        }
    }

    @Test(arguments: ["json", "mirror", "value"])
    func corruptConfigurationIsStorageFailureRatherThanSourceRevocation(kind: String) async throws {
        try await withTaskWorkflow { f in
            try await f.database.write { db in
                switch kind {
                case "json": try db.execute(sql: "UPDATE settings_connections SET json = ?", arguments: [Data("invalid configuration".utf8)])
                case "mirror": try db.execute(sql: "UPDATE settings_connections SET revision = revision + 1")
                default:
                    let old = try #require(try Data.fetchOne(db, sql: "SELECT json FROM settings_connections"))
                    guard case .object(var fields) = try SessionCodec.decode(JSONValue.self, from: old) else { throw MiraError(.storage, "Synthetic settings object is missing.") }
                    fields["revision"] = .number(-1)
                    try db.execute(sql: "UPDATE settings_connections SET json = ?", arguments: [try SessionCodec.encode(JSONValue.object(fields))])
                }
            }
            do { try await f.authorizer.validate([], for: request(f)); Issue.record("Corrupt settings were authorized") }
            catch let error as MiraError { #expect(error.code == .storage) }
        }
    }

    @Test func taskSourceVersionAndNamespaceAreCurrent() async throws {
        try await withTaskWorkflow { f in
            let task = try await f.save(draft: .init(title: "Source task"))
            let source: AgentSourceReference = .domain(namespace: "tasks", id: task.id.rawValue, revision: 1)
            try await f.authorizer.validate([source], for: request(f))
            _ = try await f.save(id: task.id, draft: .init(title: "Changed task"), expectedRevision: 1)
            await #expect(throws: MiraError.self) { try await f.authorizer.validate([source], for: request(f)) }
            await #expect(throws: MiraError.self) {
                try await f.authorizer.validate([.domain(namespace: "unregistered", id: task.id.rawValue, revision: 2)], for: request(f))
            }
        }
    }

    @Test func duplicateAuthorityNamespaceDoesNotSelectAnArbitraryOwner() async throws {
        try await withTaskWorkflow { f in
            let authority = SourceTestAuthority(namespace: "tasks")
            try await f.sourceAuthorities.register(id: "duplicate", value: authority, scope: f.scope)
            do { try await f.authorizer.validate([], for: request(f)); Issue.record("Duplicate authority namespace was accepted") }
            catch let error as MiraError { #expect(error.code == .configuration) }
            #expect(await authority.calls == 0)
        }
    }

    @Test func policyIsRecheckedAfterSuspendedDomainValidation() async throws {
        try await withTaskWorkflow { f in
            let workspace = Workspace(id: .init(), name: "Shared workspace")
            try await save(workspace, in: f)
            let authority = SourceTestAuthority(namespace: "suspended", hold: true)
            try await f.sourceAuthorities.register(id: "suspended", value: authority, scope: f.scope)
            let source: AgentSourceReference = .domain(namespace: authority.namespace, id: UUID(), revision: 1)
            let task = Task { try await f.authorizer.validate([source], for: request(f, workspaceID: workspace.id)) }
            do {
                try await taskEventually { await authority.entered }
                var revoked = workspace; revoked.revision += 1; revoked.allowsRemoteSend = false
                try await save(revoked, expectedRevision: workspace.revision, in: f)
                await authority.release()
                do { try await task.value; Issue.record("Policy change during source validation was ignored") }
                catch let error as MiraError { #expect(error.code == .unauthorized) }
            } catch { await authority.release(); _ = await task.result; throw error }
        }
    }

    @Test func moduleDisposalWaitsForActualSourceValidationAndRejectsFutureUse() async throws {
        try await withTaskWorkflow { f in
            let scope = RuntimeScope(kind: .application), probe = SourceScopeProbe()
            _ = try await scope.registerClosing { await probe.markClosing() }
            try await scope.registerCleanup { await probe.markCleaned() }
            let authority = SourceTestAuthority(namespace: "held", hold: true)
            try await f.sourceAuthorities.register(id: "held", value: authority, scope: scope)
            let source: AgentSourceReference = .domain(namespace: authority.namespace, id: UUID(), revision: 1)
            let validation = Task { try await f.authorizer.validate([source], for: request(f)) }
            var disposal: Task<Void, Never>?
            do {
                try await taskEventually { await authority.entered }
                disposal = Task { await scope.dispose() }
                try await taskEventually { await probe.closing }
                validation.cancel()
                #expect(await probe.cleaned == false)
                await authority.release()
                await #expect(throws: CancellationError.self) { try await validation.value }
                await disposal?.value
                #expect(await probe.cleaned)
                await #expect(throws: MiraError.self) { try await f.authorizer.validate([source], for: request(f)) }
            } catch { await authority.release(); _ = await validation.result; await disposal?.value; await scope.dispose(); throw error }
        }
    }

    @Test func requestWithoutExplicitDestinationCannotBeDecoded() async throws {
        try await withTaskWorkflow { f in
            let bytes = try SessionCodec.encode(request(f))
            guard case .object(var fields) = try SessionCodec.decode(JSONValue.self, from: bytes) else { Issue.record("Request is not an object"); return }
            fields["destination"] = nil
            #expect(throws: (any Error).self) { try SessionCodec.decode(AgentContextRequest.self, from: SessionCodec.encode(JSONValue.object(fields))) }
        }
    }
}

private func request(_ fixture: TaskWorkflowFixture, workspaceID: WorkspaceID? = nil,
                     destination: AgentContextDestination? = nil) -> AgentContextRequest {
    .init(sessionID: .init(), executionID: .init(), workspaceID: workspaceID,
          userText: "Synthetic source authorization", authorizationEpoch: 0, destination: destination ?? .model(fixture.route))
}
private func save(_ workspace: Workspace, expectedRevision: Int? = nil, in f: TaskWorkflowFixture) async throws {
    let lease = try await f.access.acquire(in: f.scope)
    do { try await f.workspaces.saveWorkspace(workspace, expectedRevision: expectedRevision, authorization: lease.authorization) }
    catch { await lease.release(); throw error }
    await lease.release()
}
private actor SourceTestAuthority: AgentDomainSourceAuthority {
    nonisolated let namespace: String
    private let hold: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var calls = 0
    init(namespace: String, hold: Bool = false) { self.namespace = namespace; self.hold = hold }
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        calls += 1; entered = true
        if hold { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor SourceScopeProbe {
    private(set) var closing = false
    private(set) var cleaned = false
    func markClosing() { closing = true }
    func markCleaned() { cleaned = true }
}
