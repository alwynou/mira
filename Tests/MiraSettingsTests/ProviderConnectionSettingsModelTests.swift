import XCTest
import AppKit
import SwiftUI
import MiraCore
import MiraProviders

@MainActor
final class ProviderConnectionSettingsModelTests: XCTestCase {
    func testEnableAcceptsAnUnverifiedKeyWithoutATestModel() async {
        let fake = FakeProviderConnectionStore()
        fake.storedCredential = false
        fake.testError = MiraError(.providerRejected, "Synthetic invalid credential")
        let connection = makeConnection()
        let model = ProviderConnectionSettingsModel(existing: connection, template: nil, container: fake)
        model.update(existing: connection, configuration: .init(connections: [connection], models: [], routes: [], bindings: []))
        model.secret = "synthetic-wrong-key"
        XCTAssertTrue(model.hasKey)
        XCTAssertFalse(model.canTest)
        XCTAssertNil(model.selectedModel)

        model.setEnabled(true) { _ in }
        await waitUntil { fake.saveCalls == 1 && !model.isWorking }

        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(fake.savedSecrets, ["synthetic-wrong-key"])
        XCTAssertEqual(fake.testCalls, 0)
        XCTAssertNil(model.statusKey, "Enabling must not claim the connection was tested.")
        XCTAssertNil(model.error)

        if let saved = model.baseline {
            model.update(existing: saved, configuration: makeConfiguration(connection: saved))
        }
        model.secret = "synthetic-wrong-key"
        model.test()
        await waitUntil { fake.testCalls == 1 && !model.isWorking }
        XCTAssertEqual(model.error?.code, .providerRejected)
        XCTAssertTrue(model.isEnabled, "An explicit failed test does not change the saved switch state.")
        XCTAssertEqual(fake.saveCalls, 1)
    }

    func testEmptyKeyCannotEnable() {
        let fake = FakeProviderConnectionStore()
        fake.storedCredential = false
        let model = makeModel(fake: fake, connection: makeConnection())
        model.secret = "  "
        XCTAssertFalse(model.hasKey)
        model.setEnabled(true) { _ in XCTFail("No key was entered.") }
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(fake.saveCalls, 0)
        XCTAssertEqual(fake.testCalls, 0)
        XCTAssertTrue(model.requiresAPIKey)
        model.secret = "synthetic-key"
        XCTAssertFalse(model.requiresAPIKey)
        model.secret = ""
        model.setEnabled(true) { _ in }
        XCTAssertTrue(model.requiresAPIKey)
        model.discardChanges()
        XCTAssertFalse(model.requiresAPIKey)
    }

    func testNativeEmptyKeyPromptsAndFocusesTheSecureField() async throws {
        _ = NSApplication.shared
        for (language, appearance) in [("en", NSAppearance.Name.aqua), ("zh-CN", .darkAqua)] {
            let fake = FakeProviderConnectionStore()
            fake.storedCredential = false
            let model = makeModel(fake: fake, connection: makeConnection())
            let host = NSHostingView(rootView: MiraSettingsLazyPage(header: {
                ProviderConnectionEditor(settings: model, isUnavailable: false, onMutation: {}, onSaved: { _ in })
            }, content: { EmptyView() }).environment(\.locale, Locale(identifier: language)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 552, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { model.disappear(); window.close() }
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            let toggle = try XCTUnwrap(findSwitch(in: host))
            XCTAssertTrue(toggle.isEnabled, "The empty-key switch must accept a validation attempt.")

            toggle.performClick(nil)
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(findSecureField(in: host))
            XCTAssertTrue(model.requiresAPIKey)
            XCTAssertEqual(toggle.state, .off)
            XCTAssertNotNil(field.currentEditor())
            XCTAssertTrue(field.currentEditor() === window.firstResponder)
            XCTAssertEqual(fake.saveCalls, 0)
            XCTAssertEqual(fake.testCalls, 0)
            try capture(host, name: "mira-provider-key-required-\(language)")

            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText("synthetic-entered-key", replacementRange: NSRange(location: NSNotFound, length: 0))
            await waitUntil { model.hasKey }
            XCTAssertFalse(model.requiresAPIKey)
            host.layoutSubtreeIfNeeded()
            try capture(host, name: "mira-provider-key-entered-\(language)")
            toggle.performClick(nil)
            await waitUntil { fake.saveCalls == 1 && !model.isWorking }
            XCTAssertTrue(model.isEnabled)
            XCTAssertEqual(fake.testCalls, 0)
        }
    }

    private func findSecureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap(findSecureField(in:)).first
    }

    func testNativeToggleSavesLocallyWithoutVerification() async throws {
        _ = NSApplication.shared
        for (language, appearance) in [("en", NSAppearance.Name.aqua), ("zh-CN", .darkAqua)] {
            let fake = FakeProviderConnectionStore()
            fake.blockSaves = true
            let model = makeModel(fake: fake, connection: makeConnection())
            fake.beforeSaveReturn = { [weak model] updated in
                model?.update(existing: updated, configuration: self.makeConfiguration(connection: updated))
            }
            let host = NSHostingView(rootView: MiraSettingsLazyPage(header: {
                ProviderConnectionEditor(settings: model, isUnavailable: false, onMutation: {}, onSaved: { _ in })
            }, content: { EmptyView() }).environment(\.locale, Locale(identifier: language)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 552, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { model.disappear(); window.close() }
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            let toggle = try XCTUnwrap(findSwitch(in: host))
            XCTAssertEqual(toggle.state, .off)

            let start = ContinuousClock.now
            toggle.performClick(nil)
            await waitUntil { fake.saveCalls == 1 }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(toggle.state, .on)
            XCTAssertFalse(model.isTesting)
            XCTAssertNil(model.statusKey)
            XCTAssertEqual(fake.testCalls, 0)
            XCTAssertFalse(model.baseline?.isEnabled ?? true)
            let elapsed = start.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            print("Native provider toggle pending layout (\(language)): \(milliseconds) ms")
            XCTAssertLessThan(milliseconds, 250, "Local persistence must not delay native switch feedback.")
            try capture(host, name: "mira-provider-toggle-pending-\(language)")

            fake.releaseSave()
            await waitUntil { !model.isWorking }
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(model.baseline?.isEnabled ?? false)
            XCTAssertEqual(toggle.state, .on)
            toggle.performClick(nil)
            await waitUntil { fake.saveCalls == 2 && !model.isWorking }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(toggle.state, .off)
            XCTAssertFalse(model.baseline?.isEnabled ?? true)
            XCTAssertEqual(fake.testCalls, 0, "Neither activation nor deactivation may contact a provider.")
            XCTAssertEqual(fake.credentialReads, 1)
            XCTAssertNil(model.error)
            try capture(host, name: "mira-provider-toggle-disabled-\(language)")
        }
    }

    private func findSwitch(in view: NSView) -> NSSwitch? {
        if let toggle = view as? NSSwitch { return toggle }
        return view.subviews.lazy.compactMap(findSwitch(in:)).first
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }

    func testSaveNotificationBeforeReturnDoesNotDiscardToggleResult() async {
        let fake = FakeProviderConnectionStore()
        var connection = makeConnection()
        connection.isEnabled = true
        let model = makeModel(fake: fake, connection: connection)
        fake.beforeSaveReturn = { [weak model] updated in
            model?.update(existing: updated, configuration: self.makeConfiguration(connection: updated))
        }
        var saved = false

        model.setEnabled(false) { _ in saved = true }
        await waitUntil { fake.saveCalls == 1 && !model.isWorking }

        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.baseline?.isEnabled ?? true)
        XCTAssertTrue(saved)
        XCTAssertNil(model.error)
        XCTAssertEqual(fake.credentialReads, 1, "A toggle must reuse the already-loaded credential.")
        model.setEnabled(false) { _ in }
        await Task.yield()
        XCTAssertEqual(fake.saveCalls, 1, "Selecting the current state must not write again.")
    }

    func testEnableRespondsImmediatelyAndRollsBackOnCancellation() async {
        let fake = FakeProviderConnectionStore()
        fake.blockSaves = true
        let model = makeModel(fake: fake, connection: makeConnection())

        model.setEnabled(true) { _ in }
        XCTAssertTrue(model.isEnabled, "The switch reflects the requested state while saving.")
        XCTAssertFalse(model.baseline?.isEnabled ?? true, "The pending switch does not preempt the database commit.")
        XCTAssertFalse(model.isTesting)
        await waitUntil { fake.saveCalls == 1 }
        model.cancel()

        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.error)
    }

    func testFailedDisableRestoresEnabledStateAndPreservesDraft() async {
        let fake = FakeProviderConnectionStore()
        fake.saveError = MiraError(.storage, "Synthetic save failure")
        var connection = makeConnection()
        connection.isEnabled = true
        let model = makeModel(fake: fake, connection: connection)
        model.baseURL = "https://draft.example/v1"
        model.secret = "synthetic-replacement"

        model.setEnabled(false) { _ in XCTFail("A failed save must not notify success.") }
        XCTAssertFalse(model.isEnabled)
        await waitUntil { fake.saveCalls == 1 && !model.isWorking }

        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.baseURL, "https://draft.example/v1")
        XCTAssertEqual(model.secret, "synthetic-replacement")
        XCTAssertEqual(model.error?.code, .storage)
        XCTAssertEqual(fake.testCalls, 0)
    }

    func testNewerExternalRevisionWinsOverSaveReturn() async {
        let fake = FakeProviderConnectionStore()
        var connection = makeConnection()
        connection.isEnabled = true
        let model = makeModel(fake: fake, connection: connection)
        var newest: ProviderConnection?
        fake.beforeSaveReturn = { [weak model] updated in
            var external = updated
            external.revision += 1
            external.baseURL = "https://external.example/v1"
            newest = external
            model?.update(existing: external, configuration: self.makeConfiguration(connection: external))
        }

        model.setEnabled(false) { _ in XCTFail("A superseded save must not notify success.") }
        await waitUntil { fake.saveCalls == 1 && !model.isWorking }

        XCTAssertEqual(model.baseline, newest)
        XCTAssertEqual(model.baseURL, newest?.baseURL)
        XCTAssertEqual(model.error?.code, .conflict)
    }

    func testCatalogOptionsStayStableOnUnchangedRefresh() throws {
        let fake = FakeProviderConnectionStore()
        let template = try XCTUnwrap(ProviderModelCatalog.bundled.directoryProviders.first { $0.id == "openrouter" })
        let configuration = ModelConfiguration(connections: [], models: [], routes: [], bindings: [])
        var times: [Double] = []
        for _ in 0..<10 {
            let model = ProviderConnectionSettingsModel(existing: nil, template: template, container: fake)
            let start = ContinuousClock.now
            model.update(existing: nil, configuration: configuration)
            let elapsed = start.duration(to: .now).components
            times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertGreaterThan(model.testModels.count, 300)
            let previous = model.testModels
            model.update(existing: nil, configuration: configuration)
            XCTAssertEqual(model.testModels, previous, "A refresh must not reconstruct unchanged candidate routes.")
        }
        print("OpenRouter candidate preparation milliseconds: \(times)")
        XCTAssertEqual(fake.testCalls, 0)
        XCTAssertEqual(fake.saveCalls, 0)
    }

    func testSaveDoesNotTestConnection() async {
        let fake = FakeProviderConnectionStore()
        let connection = makeConnection()
        let model = makeModel(fake: fake, connection: connection)
        XCTAssertTrue(model.hasStoredKey)
        XCTAssertEqual(model.secret, "synthetic-stored-key")
        model.baseURL = "https://changed.example/v1"

        model.save { _ in }
        await waitUntil { fake.saveCalls == 1 && model.baseline?.baseURL == "https://changed.example/v1" }

        XCTAssertEqual(fake.saveCalls, 1)
        XCTAssertEqual(fake.testCalls, 0)
        XCTAssertEqual(fake.savedSecrets, [""], "Displaying the saved key must not rotate its credential version on an unrelated save.")
        XCTAssertEqual(model.secret, "synthetic-stored-key")
        XCTAssertEqual(model.baseline?.baseURL, "https://changed.example/v1")
    }

    func testWindowClosureClearsStoredAndReplacementKeyState() async {
        let fake = FakeProviderConnectionStore()
        let connection = makeConnection()
        let model = makeModel(fake: fake, connection: connection)
        model.secret = "synthetic-replacement-key"
        model.test()
        await waitUntil { fake.testCalls == 1 && !model.isWorking }

        XCTAssertEqual(fake.testedSecrets, ["synthetic-replacement-key"])
        XCTAssertEqual(fake.saveCalls, 0)
        model.disappear()
        XCTAssertTrue(model.secret.isEmpty)
        XCTAssertFalse(model.hasStoredKey)
        XCTAssertFalse(model.hasChanges)
        XCTAssertNil(model.statusKey)
    }

    func testDisablePreservesUnsavedEndpointAndKeyDraft() async {
        let fake = FakeProviderConnectionStore()
        var connection = makeConnection()
        connection.isEnabled = true
        let model = makeModel(fake: fake, connection: connection)
        model.secret = "synthetic-replacement-key"
        model.baseURL = "https://draft.example/v1"

        model.setEnabled(false) { _ in }
        await waitUntil { fake.saveCalls == 1 && !model.isWorking }

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.baseline?.baseURL, connection.baseURL)
        XCTAssertEqual(model.baseURL, "https://draft.example/v1")
        XCTAssertEqual(model.secret, "synthetic-replacement-key")
        XCTAssertEqual(fake.savedSecrets, [""])
        XCTAssertEqual(fake.testCalls, 0)
    }

    func testFailedEnableDoesNotUpdateBaseline() async {
        let fake = FakeProviderConnectionStore()
        fake.saveError = MiraError(.storage, "synthetic failure")
        let connection = makeConnection()
        let model = makeModel(fake: fake, connection: connection)
        model.baseURL = "https://changed.example/v1"

        model.setEnabled(true) { _ in }
        await waitUntil { fake.saveCalls == 1 && !model.isWorking }

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.baseline?.baseURL, connection.baseURL)
        XCTAssertNotNil(model.error)
    }

    func testCancelledEnableDoesNotUpdateBaseline() async {
        let fake = FakeProviderConnectionStore()
        fake.blockSaves = true
        let connection = makeConnection()
        let model = makeModel(fake: fake, connection: connection)
        model.baseURL = "https://changed.example/v1"

        model.setEnabled(true) { _ in }
        await waitUntil { fake.saveCalls == 1 }
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
    var savedSecrets: [String] = []
    var testedSecrets: [String] = []
    var blockTests = false
    var blockSaves = false
    var testError: Error?
    var saveError: Error?
    var credentialReads = 0
    var beforeSaveReturn: ((ProviderConnection) -> Void)?
    private var pendingTest: CheckedContinuation<Void, Error>?
    private var pendingSave: CheckedContinuation<Void, Error>?

    func credential(for connection: ProviderConnection) -> String? {
        credentialReads += 1
        return storedCredential ? "synthetic-stored-key" : nil
    }

    func testConnection(_ connection: ProviderConnection, previous: ProviderConnection?, secret: String,
                        model: ProviderConnectionTestModel) async throws {
        testCalls += 1
        testedSecrets.append(secret)
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

    func saveConnection(_ route: ProviderConnection, previous: ProviderConnection?, secret: String) async throws -> ProviderConnection {
        saveCalls += 1
        savedSecrets.append(secret)
        if let saveError { throw saveError }
        if blockSaves {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { pendingSave = $0 }
            }, onCancel: {
                Task { @MainActor in
                    self.pendingSave?.resume(throwing: CancellationError())
                    self.pendingSave = nil
                }
            })
        }
        try Task.checkCancellation()
        beforeSaveReturn?(route)
        return route
    }

    func releaseSave() {
        blockSaves = false
        pendingSave?.resume()
        pendingSave = nil
    }

    func releaseTest() {
        pendingTest?.resume()
        pendingTest = nil
    }
}
