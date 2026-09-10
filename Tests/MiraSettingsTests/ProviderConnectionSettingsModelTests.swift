import XCTest
import MiraCore
import MiraProviders

@MainActor
final class ProviderConnectionSettingsModelTests: XCTestCase {
    func testSaveDoesNotTestConnection() async {
        let fake = FakeProviderConnectionStore()
        let connection = makeConnection()
        let model = makeModel(fake: fake, connection: connection)
        model.baseURL = "https://changed.example/v1"

        model.save { _ in }
        await waitUntil { fake.saveCalls == 1 && model.baseline?.baseURL == "https://changed.example/v1" }

        XCTAssertEqual(fake.saveCalls, 1)
        XCTAssertEqual(fake.testCalls, 0)
        XCTAssertEqual(model.baseline?.baseURL, "https://changed.example/v1")
    }

    func testFailedEnableDoesNotUpdateBaseline() async {
        let fake = FakeProviderConnectionStore()
        fake.testError = MiraError(.providerRejected, "synthetic failure")
        let connection = makeConnection()
        let model = makeModel(fake: fake, connection: connection)
        model.baseURL = "https://changed.example/v1"

        model.setEnabled(true) { _ in }
        await waitUntil { fake.testCalls == 1 && !model.isWorking }

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.baseline?.baseURL, connection.baseURL)
        XCTAssertNotNil(model.error)
    }

    func testCancelledEnableDoesNotUpdateBaseline() async {
        let fake = FakeProviderConnectionStore()
        fake.blockTests = true
        let connection = makeConnection()
        let model = makeModel(fake: fake, connection: connection)
        model.baseURL = "https://changed.example/v1"

        model.setEnabled(true) { _ in }
        await waitUntil { fake.testCalls == 1 }
        model.cancel()
        await waitUntil { !model.isWorking }

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.baseline?.baseURL, connection.baseURL)
        XCTAssertNil(model.error)
    }

    func testDraftEditInvalidatesStaleSuccessfulTest() async {
        let fake = FakeProviderConnectionStore()
        fake.blockTests = true
        let connection = makeConnection()
        let model = makeModel(fake: fake, connection: connection)

        model.test()
        await waitUntil { fake.testCalls == 1 }
        model.baseURL = "https://changed.example/v1"
        fake.releaseTest()
        await waitUntil { !model.isWorking }

        XCTAssertNil(model.statusKey)
        XCTAssertNil(model.error)
    }

    func testExternalChangePreservesConflictErrorAndDiscardUsesLatest() async {
        let fake = FakeProviderConnectionStore()
        let original = makeConnection()
        let model = makeModel(fake: fake, connection: original)
        model.baseURL = "https://draft.example/v1"
        var latest = original
        latest.revision += 1
        latest.baseURL = "https://latest.example/v1"

        model.update(existing: latest, configuration: makeConfiguration(connection: latest))
        XCTAssertTrue(model.error?.message.contains("changed") == true)

        model.discardChanges()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.baseURL, latest.baseURL)
        XCTAssertFalse(model.hasChanges)
    }

    func testWhitespaceOnlyEditsAreNotDirty() {
        let fake = FakeProviderConnectionStore()
        let connection = makeConnection()
        let model = makeModel(fake: fake, connection: connection)
        model.baseURL = "  \(connection.baseURL)  "
        model.secret = "   "

        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.canSave)
    }

    private func makeModel(fake: FakeProviderConnectionStore, connection: ProviderConnection) -> ProviderConnectionSettingsModel {
        let model = ProviderConnectionSettingsModel(existing: connection, template: nil, container: fake)
        model.update(existing: connection, configuration: makeConfiguration(connection: connection))
        return model
    }

    private func makeConnection() -> ProviderConnection {
        ProviderConnection(name: "Fixture", providerKind: .openAICompatible,
                           baseURL: "https://fixture.example/v1", credentialReference: "fixture-key",
                           isEnabled: false)
    }

    private func makeConfiguration(connection: ProviderConnection) -> ModelConfiguration {
        let descriptor = ModelDescriptor(connectionID: connection.id, connectionRevision: connection.revision,
                                         modelID: "fixture-model", contextWindow: 4096, textCapability: .declared)
        let route = ModelRoute(id: descriptor.poolRouteID, name: "Fixture", modelDescriptorID: descriptor.id,
                               maxOutputTokens: 1024)
        return ModelConfiguration(connections: [connection], models: [descriptor], routes: [route], bindings: [])
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The synthetic operation did not reach its expected state.")
    }
}

@MainActor
private final class FakeProviderConnectionStore: ProviderConnectionSettingsStore {
    let isDemo = false
    var storedCredential = true
    var testCalls = 0
    var saveCalls = 0
    var blockTests = false
    var testError: Error?
    private var pendingTest: CheckedContinuation<Void, Error>?

    func hasCredential(for connection: ProviderConnection) -> Bool { storedCredential }

    func testConnection(_ connection: ProviderConnection, previous: ProviderConnection?, secret: String,
                        model: ProviderConnectionTestModel) async throws {
        testCalls += 1
        if let testError { throw testError }
        guard blockTests else { return }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pendingTest = continuation
            }
        }, onCancel: {
            Task { @MainActor in
                self.pendingTest?.resume(throwing: CancellationError())
                self.pendingTest = nil
            }
        })
    }

    func saveConnection(_ route: ProviderConnection, previous: ProviderConnection?, secret: String,
                        testModel: ProviderConnectionTestModel?) async throws -> ProviderConnection {
        saveCalls += 1
        if route.isEnabled && previous?.isEnabled != true {
            let model = try XCTUnwrap(testModel)
            try await testConnection(route, previous: previous, secret: secret, model: model)
        }
        try Task.checkCancellation()
        return route
    }

    func releaseTest() {
        pendingTest?.resume()
        pendingTest = nil
    }
}
