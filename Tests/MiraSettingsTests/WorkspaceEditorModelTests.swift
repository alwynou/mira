import MiraCore
import XCTest

@MainActor
final class WorkspaceEditorModelTests: XCTestCase {
    func testLoadsAtMost128ConnectionsAndSavesTheNextWorkspaceRevision() async throws {
        let fixture = try await WorkspaceEditorFixture.make()
        addTeardownBlock { await fixture.close() }
        let settings = FakeModelSettings(
            connections: (0..<130).map { index in
                AgentConfiguredConnection(
                    id: .init(), revision: 1, configurationRevision: 1,
                    name: "Connection \(index)", isEnabled: true, definitionID: nil,
                    endpoints: [.init(id: "primary", configuration: .init(
                        schema: .init(id: "tests.settings", revision: 1), value: .object([:])), credential: nil)],
                    discovery: nil, defaultInvocation: nil)
            })
        let original = Workspace(id: .init(), name: "Original", revision: 1)
        try await fixture.store.saveWorkspace(original, expectedRevision: nil, authorization: fixture.authorization)
        let model = WorkspaceEditorModel(workspaces: fixture.application, settings: settings, workspace: original)

        await model.loadConnections()
        XCTAssertEqual(model.connections.count, 128)
        let lastLimit = await settings.lastLimit
        XCTAssertEqual(lastLimit, 128)

        model.name = "Updated"
        let savedResult = await model.save()
        XCTAssertTrue(savedResult)
        let saved = try await fixture.store.workspace(original.id)
        XCTAssertEqual(saved.name, "Updated")
        XCTAssertEqual(saved.revision, 2)
    }

    func testConflictLeavesDraftAndPublishesServiceError() async throws {
        let fixture = try await WorkspaceEditorFixture.make()
        addTeardownBlock { await fixture.close() }
        let original = Workspace(id: .init(), name: "Original", revision: 1)
        try await fixture.store.saveWorkspace(original, expectedRevision: nil, authorization: fixture.authorization)
        let model = WorkspaceEditorModel(
            workspaces: fixture.application, settings: FakeModelSettings(connections: []), workspace: original)
        model.name = "My draft"

        var changed = original
        changed.name = "Concurrent"
        changed.revision = 2
        try await fixture.store.saveWorkspace(changed, expectedRevision: 1, authorization: fixture.authorization)

        let saveResult = await model.save()
        XCTAssertFalse(saveResult)
        XCTAssertEqual(model.name, "My draft")
        XCTAssertEqual(model.error?.code, .conflict)
    }

    func testCancelledSaveDoesNotPublishAnOldErrorAfterTheAcceptedStoreCallReturns() async throws {
        let gate = SaveGate()
        let fixture = try await WorkspaceEditorFixture.make(saveGate: gate)
        addTeardownBlock { await fixture.close() }
        let original = Workspace(id: .init(), name: "Original", revision: 1)
        try await fixture.store.saveWorkspace(original, expectedRevision: nil, authorization: fixture.authorization)
        await fixture.armSaveGate()
        let settings = FakeModelSettings(connections: [], failure: MiraError(.storage, "Old error"))
        let model = WorkspaceEditorModel(workspaces: fixture.application, settings: settings, workspace: original)
        model.name = "Saved after cancellation"
        await model.loadConnections()
        XCTAssertEqual(model.error?.message, "Old error")

        let saving = Task { await model.save() }
        guard await gate.waitUntilEntered() else {
            XCTFail("The accepted workspace save did not reach the store.")
            await gate.release()
            return
        }
        saving.cancel()
        await gate.release()
        let saveResult = await saving.value
        XCTAssertFalse(saveResult)
        XCTAssertNil(model.error)
        let saved = try await fixture.store.workspace(original.id)
        XCTAssertEqual(saved.name, "Saved after cancellation")
        XCTAssertEqual(saved.id, original.id)

        model.name = "Saved again"
        let secondSaveResult = await model.save()
        XCTAssertTrue(secondSaveResult)
        let savedAgain = try await fixture.store.workspace(original.id)
        XCTAssertEqual(savedAgain.id, original.id)
        XCTAssertEqual(savedAgain.revision, 3)
    }

    func testPresentationInvalidationSuppressesLateSuccessButKeepsCommittedRevision() async throws {
        let gate = SaveGate()
        let fixture = try await WorkspaceEditorFixture.make(saveGate: gate)
        addTeardownBlock { await fixture.close() }
        let original = Workspace(id: .init(), name: "Original", revision: 1)
        try await fixture.store.saveWorkspace(original, expectedRevision: nil, authorization: fixture.authorization)
        await fixture.armSaveGate()
        let model = WorkspaceEditorModel(
            workspaces: fixture.application, settings: FakeModelSettings(connections: []), workspace: original)
        model.name = "Committed while leaving"

        let saving = Task { await model.save() }
        guard await gate.waitUntilEntered() else {
            XCTFail("The accepted workspace save did not reach the store.")
            await gate.release()
            return
        }
        model.invalidatePresentation()
        await gate.release()

        let saveResult = await saving.value
        XCTAssertFalse(saveResult)
        let saved = try await fixture.store.workspace(original.id)
        XCTAssertEqual(saved.name, "Committed while leaving")
        XCTAssertEqual(saved.revision, 2)

        model.name = "Committed again"
        let secondSaveResult = await model.save()
        XCTAssertTrue(secondSaveResult)
        let savedAgain = try await fixture.store.workspace(original.id)
        XCTAssertEqual(savedAgain.revision, 3)
    }

    func testCancelledCreationContinuesWithTheSameWorkspaceIdentity() async throws {
        let gate = SaveGate()
        let fixture = try await WorkspaceEditorFixture.make(saveGate: gate)
        addTeardownBlock { await fixture.close() }
        await fixture.armSaveGate()
        let model = WorkspaceEditorModel(
            workspaces: fixture.application, settings: FakeModelSettings(connections: []), workspace: nil)
        model.name = "Created once"
        let saving = Task { await model.save() }
        guard await gate.waitUntilEntered() else {
            XCTFail("The accepted creation did not reach the store.")
            await gate.release()
            return
        }
        saving.cancel()
        await gate.release()
        let displayedSuccess = await saving.value
        XCTAssertFalse(displayedSuccess)
        let initial = try await fixture.store.workspaces()
        XCTAssertEqual(initial.count, 1)
        model.name = "Updated after cancellation"
        let updatedSuccess = await model.save()
        XCTAssertTrue(updatedSuccess)
        let updated = try await fixture.store.workspaces()
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.id, initial.first?.id)
        XCTAssertEqual(updated.first?.revision, 2)
    }
}

private final class WorkspaceEditorFixture: @unchecked Sendable {
    let store: InMemoryWorkspaceStore
    let application: WorkspaceApplication
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let authorization: AgentLibraryAuthorization

    private init(
        store: InMemoryWorkspaceStore, application: WorkspaceApplication,
        access: AgentLibraryAccess, scope: RuntimeScope, authorization: AgentLibraryAuthorization
    ) {
        self.store = store
        self.application = application
        self.access = access
        self.scope = scope
        self.authorization = authorization
    }

    static func make(saveGate: SaveGate? = nil) async throws -> WorkspaceEditorFixture {
        let authorization = AgentLibraryAuthorization(libraryID: UUID(), epoch: 0)
        let maintenance = InMemoryMaintenanceStore(authorization: authorization)
        let access = try await AgentLibraryAccess.open(store: maintenance)
        let scope = RuntimeScope(kind: .application)
        let store = InMemoryWorkspaceStore(saveGate: saveGate)
        let application = WorkspaceApplication(store: store, access: access, scope: scope)
        return .init(store: store, application: application, access: access, scope: scope, authorization: authorization)
    }

    func close() async {
        await store.releaseSaveGate()
        await application.close()
        await access.close()
        await scope.dispose()
    }

    func armSaveGate() async {
        await store.armSaveGate()
    }
}

private actor InMemoryWorkspaceStore: WorkspaceStore {
    private var values: [WorkspaceID: Workspace] = [:]
    private let saveGate: SaveGate?

    init(saveGate: SaveGate? = nil) { self.saveGate = saveGate }

    func armSaveGate() async {
        await saveGate?.arm()
    }

    func releaseSaveGate() async {
        await saveGate?.release()
    }

    func workspaces() async throws -> [Workspace] {
        values.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    func workspace(_ id: WorkspaceID) async throws -> Workspace {
        guard let value = values[id] else { throw MiraError(.notFound, "The workspace does not exist.") }
        return value
    }

    func saveWorkspace(_ workspace: Workspace, expectedRevision: Int?, authorization: AgentLibraryAuthorization)
        async throws
    {
        await saveGate?.waitIfArmed()
        guard values[workspace.id]?.revision == expectedRevision,
            workspace.revision == (values[workspace.id]?.revision ?? 0) + 1
        else {
            throw MiraError(.conflict, "The workspace revision is out of date.")
        }
        values[workspace.id] = workspace
    }
}

private actor SaveGate {
    private var armed = false
    private var entered = false
    private var released = true
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        armed = true
        entered = false
        released = false
    }

    func waitIfArmed() async {
        guard armed else { return }
        armed = false
        entered = true
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered(timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return entered
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor InMemoryMaintenanceStore: AgentLibraryMaintenanceStore {
    let authorization: AgentLibraryAuthorization

    init(authorization: AgentLibraryAuthorization) { self.authorization = authorization }

    func state() async throws -> AgentLibraryMaintenanceState { .init(authorization: authorization, pending: nil) }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { nil }
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws
        -> AgentLibraryMaintenanceOperation
    {
        throw MiraError(.unsupported, "Synthetic maintenance is unavailable.")
    }
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws
        -> AgentLibraryMaintenanceOperation
    {
        throw MiraError(.unsupported, "Synthetic maintenance is unavailable.")
    }
}

private actor FakeModelSettings: MacModelSettings {
    private let values: [AgentConfiguredConnection]
    private let failure: MiraError?
    private(set) var lastLimit: Int?

    init(connections: [AgentConfiguredConnection], failure: MiraError? = nil) {
        values = connections
        self.failure = failure
    }

    func connection(id: ConnectionID) async throws -> AgentConfiguredConnection? { values.first { $0.id == id } }
    func discoverySnapshot(connectionID: ConnectionID) async throws -> AgentModelDiscoverySnapshot? { nil }
    func model(id: ModelDescriptorID) async throws -> AgentConfiguredModel? { nil }
    func preset(id: RouteID) async throws -> AgentRoutePreset? { nil }
    func connections(after: ConnectionID?, limit: Int) async throws -> [AgentConfiguredConnection] {
        if let failure { throw failure }
        lastLimit = limit
        return Array(values.prefix(limit))
    }
    func models(connectionID: ConnectionID?, after: ModelDescriptorID?, limit: Int) async throws
        -> [AgentConfiguredModel]
    { [] }
    func presets(modelID: ModelDescriptorID?, after: RouteID?, limit: Int) async throws -> [AgentRoutePreset] { [] }
    func ensureConversationDefault() async throws -> AgentRouteBinding? { nil }
    func bindings(scope: AgentRouteScope) async throws -> [AgentRouteBinding] { [] }
    func candidate(routeID: RouteID) async throws -> AgentModelRouteCandidate {
        throw MiraError(.notFound, "The synthetic route is unavailable.")
    }
    func configurationDescriptors(for invocation: AgentModelInvocationSpec) async throws -> [AgentModelConfigurationDescriptor] { [] }
    func discoveryDescriptors() async throws -> [AgentModelDiscoveryDescriptor] { [] }
    func resolve(
        purpose: String, explicitRouteID: RouteID?, sessionSelection: AgentSessionModelSelection,
        workspaceID: WorkspaceID?,
        requiredCapabilities: Set<String>
    ) async throws -> AgentModelRouteResolution {
        throw MiraError(.notFound, "The synthetic route is unavailable.")
    }
    func saveModel(_ value: AgentConfiguredModel, expectedRevision: Int?) async throws {}
    func savePreset(_ value: AgentRoutePreset, expectedRevision: Int?) async throws {}
    func savePoolModel(
        _ model: AgentConfiguredModel, preset: AgentRoutePreset,
        expectedModelRevision: Int?, expectedPresetRevision: Int?
    ) async throws {}
    func saveBinding(_ value: AgentRouteBinding, expectedRevision: Int?) async throws {}
    func deleteModel(id: ModelDescriptorID, expectedRevision: Int) async throws {}
    func deletePreset(id: RouteID, expectedRevision: Int) async throws {}
    func deleteBinding(scope: AgentRouteScope, purpose: String, expectedRevision: Int) async throws {}
}
