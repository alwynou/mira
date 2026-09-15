import Foundation
import MiraCore
import MiraData

extension ScaleProbe {
    static func measureRuntime(_ root: URL) async throws {
        let manifest = try SessionCodec.decode(
            Manifest.self, from: Data(contentsOf: root.appendingPathComponent("scale.json")))
        guard manifest.format == format, (1...1_000).contains(manifest.sessions),
              manifest.messagesPerSession == turns * 2, manifest.textBytes == textBytes else {
            throw failure("The synthetic corpus manifest is invalid.")
        }

        let journalStart = ContinuousClock.now
        let library = try FileSessionLibrary(directory: root.appendingPathComponent("Sessions"))
        let journalOpen = ms(journalStart)
        var inventory: [ConversationID] = []
        var cursor: ConversationID?
        while true {
            let page = try await library.sessions(after: cursor, limit: 128)
            inventory += page
            guard inventory.count <= manifest.sessions else {
                throw failure("The session inventory contains unexpected sessions.")
            }
            guard let last = page.last else { break }
            cursor = last
        }
        let expected = (0..<manifest.sessions).map { ConversationID(identifier(2, $0)) }
        guard inventory == expected else { throw failure("The session inventory does not match the manifest.") }

        let calls = ScaleProbeCallCounter()
        let maintenance = ScaleProbeMaintenanceStore(libraryID: UUID(), counter: calls)
        let access = try await AgentLibraryAccess.open(store: maintenance)
        let registry = RuntimeRegistry<AgentCapability>()
        let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 1)
        let applicationStart = ContinuousClock.now
        let runtime: AgentApplicationRuntime
        do {
            runtime = try await AgentApplicationRuntime.open(
                journal: library, payloads: library, libraryAccess: access, registry: registry, modules: [],
                policy: ScaleProbeToolPolicy(counter: calls), authority: ScaleProbeEffectAuthority(counter: calls),
                business: ScaleProbeBusinessEffects(counter: calls), authorizer: ScaleProbeSourceAuthorizer(counter: calls),
                approvals: RuntimeApprovalService(), scheduler: scheduler)
        } catch {
            await access.close(); try? await library.close(); throw error
        }
        let applicationRuntimeOpen = ms(applicationStart)
        let snapshot = await runtime.snapshot()
        guard snapshot.phase == .ready, snapshot.pendingAdmissions.isEmpty,
              snapshot.pendingSessionCommands.isEmpty, snapshot.ownedExecutions.isEmpty,
              snapshot.recoveryResults.isEmpty, snapshot.settlementFailures.isEmpty else {
            _ = await runtime.shutdown(); await access.close(); try? await library.close()
            throw failure("The runtime did not start in a quiescent ready state.")
        }
        let ready = ms(journalStart)
        let shutdown = await runtime.shutdown()
        guard shutdown.isSettled else { await access.close(); try? await library.close(); throw failure("Runtime shutdown was not settled.") }
        await access.close()
        try await library.close()
        try await calls.assertZero()
        try emit(operation: "runtime", count: manifest.sessions,
                 times: ["journalOpen": journalOpen, "applicationRuntimeOpen": applicationRuntimeOpen,
                         "runtimeReady": ready])
    }
}

private actor ScaleProbeCallCounter {
    private var value = 0
    func record() { value += 1 }
    func assertZero() throws { guard value == 0 else { throw MiraError(.storage, "Runtime startup performed an operational port call.") } }
}

private actor ScaleProbeMaintenanceStore: AgentLibraryMaintenanceStore {
    private let authorizationValue: AgentLibraryAuthorization
    private let counter: ScaleProbeCallCounter
    init(libraryID: UUID, counter: ScaleProbeCallCounter) { authorizationValue = .init(libraryID: libraryID, epoch: 0); self.counter = counter }
    func state() async throws -> AgentLibraryMaintenanceState { .init(authorization: authorizationValue, pending: nil) }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { await counter.record(); throw MiraError(.unsupported, "Unexpected maintenance operation lookup.") }
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation { await counter.record(); throw MiraError(.unsupported, "Unexpected maintenance begin.") }
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws -> AgentLibraryMaintenanceOperation { await counter.record(); throw MiraError(.unsupported, "Unexpected maintenance completion.") }
}

private struct ScaleProbeToolPolicy: AgentToolPolicy {
    let counter: ScaleProbeCallCounter
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision { await counter.record(); throw MiraError(.unsupported, "Unexpected tool policy evaluation.") }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws { await counter.record(); throw MiraError(.unsupported, "Unexpected tool policy validation.") }
}

private struct ScaleProbeEffectAuthority: AgentEffectAuthority {
    let counter: ScaleProbeCallCounter
    func authorization(for proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentLibraryAuthorization { await counter.record(); throw MiraError(.unsupported, "Unexpected effect authorization.") }
    func validate(_ authorization: AgentLibraryAuthorization, proposal: AgentToolProposal, context: AgentToolContext) async throws { await counter.record(); throw MiraError(.unsupported, "Unexpected effect validation.") }
}

private struct ScaleProbeBusinessEffects: AgentBusinessEffects {
    let counter: ScaleProbeCallCounter
    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws { await counter.record(); throw MiraError(.unsupported, "Unexpected business fence.") }
    func commit(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome { await counter.record(); return .notCommitted(.init(.unsupported, "Unexpected business commit.")) }
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup { await counter.record(); return .absent }
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] { await counter.record(); return [] }
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws { await counter.record(); throw MiraError(.unsupported, "Unexpected receipt acknowledgement.") }
}

private struct ScaleProbeSourceAuthorizer: AgentSourceAuthorizer {
    let counter: ScaleProbeCallCounter
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws { await counter.record(); throw MiraError(.unsupported, "Unexpected source authorization.") }
}
