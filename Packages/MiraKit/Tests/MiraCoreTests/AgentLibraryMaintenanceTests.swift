import Foundation
import Testing
@testable import MiraCore

@Suite("Agent library maintenance")
struct AgentLibraryMaintenanceTests {
    @Test func authorizationAndTypedSourceRequestsRoundTripWithoutPayloads() throws {
        let libraryID = UUID()
        let authorization = AgentLibraryAuthorization(libraryID: libraryID, epoch: 7)
        let scope: AgentLibraryMaintenanceScope = .sources([
            .domain(namespace: "memory", id: UUID(), revision: 3),
            .sessionExecution(sessionID: ConversationID(), executionID: ExecutionID())
        ])
        let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "memory.purge", revision: 2,
            scope: scope, requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let operation = AgentLibraryMaintenanceOperation(request: request,
            previousAuthorization: authorization,
            authorization: .init(libraryID: libraryID, epoch: 8),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001))

        try request.validate()
        try operation.validate()
        #expect(try JSONDecoder().decode(AgentLibraryAuthorization.self,
            from: JSONEncoder().encode(authorization)) == authorization)
        #expect(try JSONDecoder().decode(AgentLibraryMaintenanceRequest.self,
            from: JSONEncoder().encode(request)) == request)
        #expect(try JSONDecoder().decode(AgentLibraryMaintenanceOperation.self,
            from: JSONEncoder().encode(operation)) == operation)
    }

    @Test func sourceScopeRequiresBoundedUniqueValidatedIdentities() {
        let source = AgentSourceReference.domain(namespace: "memory", id: UUID(), revision: 1)
        #expect(throws: MiraError.self) {
            try AgentLibraryMaintenanceScope.sources([]).validate()
        }
        #expect(throws: MiraError.self) {
            try AgentLibraryMaintenanceScope.sources([source, source]).validate()
        }
        let tooMany = (0...8_192).map { _ in
            AgentSourceReference.domain(namespace: "memory", id: UUID(), revision: 1)
        }
        #expect(throws: MiraError.self) {
            try AgentLibraryMaintenanceScope.sources(tooMany).validate()
        }
        #expect(throws: MiraError.self) {
            try AgentLibraryMaintenanceScope.sources([.domain(namespace: "memory", id: UUID(), revision: 0)]).validate()
        }
    }

    @Test func requestRejectsBadNamespaceRevisionAndNonFiniteDate() {
        for request in [
            makeRequest(namespace: "", revision: 1),
            makeRequest(namespace: "bad namespace", revision: 1),
            makeRequest(namespace: "memory.purge", revision: 0),
            makeRequest(namespace: "memory.purge", revision: 1,
                        requestedAt: Date(timeIntervalSince1970: .infinity))
        ] {
            #expect(throws: MiraError.self) { try request.validate() }
        }
    }

    @Test func operationRequiresContinuousLibraryAuthorizationAndFiniteCompletion() {
        let request = makeRequest()
        let libraryID = UUID()
        let previous = AgentLibraryAuthorization(libraryID: libraryID, epoch: 4)
        let valid = AgentLibraryMaintenanceOperation(request: request, previousAuthorization: previous,
            authorization: .init(libraryID: libraryID, epoch: 5), completedAt: nil)
        #expect(throws: Never.self) { try valid.validate() }

        let wrongLibrary = AgentLibraryMaintenanceOperation(request: request, previousAuthorization: previous,
            authorization: .init(libraryID: UUID(), epoch: 5), completedAt: nil)
        let wrongEpoch = AgentLibraryMaintenanceOperation(request: request, previousAuthorization: previous,
            authorization: .init(libraryID: libraryID, epoch: 6), completedAt: nil)
        let overflow = AgentLibraryMaintenanceOperation(request: request,
            previousAuthorization: .init(libraryID: libraryID, epoch: UInt64.max),
            authorization: .init(libraryID: libraryID, epoch: 0), completedAt: nil)
        let nonFiniteCompletion = AgentLibraryMaintenanceOperation(request: request,
            previousAuthorization: previous, authorization: .init(libraryID: libraryID, epoch: 5),
            completedAt: Date(timeIntervalSince1970: -.infinity))
        for operation in [wrongLibrary, wrongEpoch, overflow, nonFiniteCompletion] {
            #expect(throws: MiraError.self) { try operation.validate() }
        }
    }

    @Test func pendingStateNeverGrantsAuthorizationAndReadyStateReturnsExactValue() async throws {
        let libraryID = UUID()
        let authorization = AgentLibraryAuthorization(libraryID: libraryID, epoch: 9)
        let pending = AgentLibraryMaintenanceOperation(request: makeRequest(),
            previousAuthorization: authorization,
            authorization: .init(libraryID: libraryID, epoch: 10), completedAt: nil)
        let pendingStore = MaintenanceStore(state: .init(authorization: pending.authorization, pending: pending))
        do {
            _ = try await pendingStore.authorization()
            Issue.record("Pending maintenance incorrectly granted authorization")
        } catch let error as MiraError {
            #expect(error.code == .unauthorized)
        }

        let readyStore = MaintenanceStore(state: .init(authorization: authorization, pending: nil))
        #expect(try await readyStore.authorization() == authorization)
    }

    @Test func storeStateErrorsPropagateWithoutBeingReclassified() async throws {
        let expected = MiraError(.storage, "Synthetic maintenance state read failure.")
        let store = MaintenanceStore(state: nil, error: expected)
        do {
            _ = try await store.authorization()
            Issue.record("Maintenance state failure was swallowed")
        } catch let error as MiraError {
            #expect(error == expected)
        }
    }

    private func makeRequest(namespace: String = "memory.purge", revision: Int = 1,
                             requestedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> AgentLibraryMaintenanceRequest {
        .init(id: UUID(), namespace: namespace, revision: revision,
              scope: .sources([.domain(namespace: "memory", id: UUID(), revision: 1)]), requestedAt: requestedAt)
    }
}

private actor MaintenanceStore: AgentLibraryMaintenanceStore {
    let storedState: AgentLibraryMaintenanceState?
    let stateError: MiraError?

    init(state: AgentLibraryMaintenanceState?, error: MiraError? = nil) {
        storedState = state; stateError = error
    }

    func state() async throws -> AgentLibraryMaintenanceState {
        if let stateError { throw stateError }
        guard let storedState else { throw MiraError(.storage, "Missing synthetic state.") }
        return storedState
    }

    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { nil }

    func begin(_ request: AgentLibraryMaintenanceRequest,
               expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        throw MiraError(.unsupported, "Synthetic store does not begin maintenance.")
    }

    func complete(_ operation: AgentLibraryMaintenanceOperation,
                  at date: Date) async throws -> AgentLibraryMaintenanceOperation {
        throw MiraError(.unsupported, "Synthetic store does not complete maintenance.")
    }
}
