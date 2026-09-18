import Foundation
import MiraCore
import MiraProviders
import XCTest

@MainActor
final class ProviderConnectionSettingsHostTests: XCTestCase {
    func testEmptyKeyRequiresInputWithoutWriting() async throws {
        try await withLibrary { library, credentials in
            let provider = try XCTUnwrap(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let model = ProviderConnectionSettingsModel(existing: nil, template: provider, library: library, isDemo: false)
            model.setEnabled(true) { _ in XCTFail("An empty key must not be saved.") }
            XCTAssertTrue(model.requiresAPIKey)
            XCTAssertEqual(credentials.saveCount, 0)
        }
    }

    func testSaveCommitsConnectionWithoutAProbe() async throws {
        try await withLibrary { library, credentials in
            let group = try await library.workloads()
            let provider = try XCTUnwrap(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let model = ProviderConnectionSettingsModel(existing: nil, template: provider, library: library, isDemo: false)
            model.secret = "synthetic-save-secret"
            var saved: AgentConfiguredConnection?
            model.save { connection in saved = connection }
            await model.waitForAction()
            let connection = try XCTUnwrap(saved)
            XCTAssertEqual(model.baseline, connection)
            XCTAssertTrue(model.hasStoredKey)
            XCTAssertEqual(credentials.saveCount, 1)
            let persisted = try await group.modelSettings.connection(id: connection.id)
            XCTAssertEqual(persisted, connection)
        }
    }

    func testUnknownModelCanBeConfiguredWithoutContextMetadata() async throws {
        try await withLibrary { library, _ in
            let provider = try XCTUnwrap(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let connection = try provider.makeConnection(credential: .init(reference: "fixture", version: 1))
            let configured = try ProviderModelCatalog.bundled.configuration(
                connection: connection, modelID: "unknown-model", isEnabled: true)
            XCTAssertNil(configured.model.invocations.first?.contextWindow)
            XCTAssertNoThrow(try configured.model.validate())
            XCTAssertNoThrow(try configured.preset.validate())
            _ = library
        }
    }

    private func withLibrary<T>(_ body: (MacLibrary, SettingsTestCredentials) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-settings-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let credentials = SettingsTestCredentials()
        let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: SettingsTestNotifications(), credentials: credentials, modules: { _ in [] })
        do {
            let value = try await body(library, credentials)
            _ = await library.close()
            try? FileManager.default.removeItem(at: directory)
            return value
        } catch {
            _ = await library.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private struct SettingsTestNotifications: LocalNotificationPort {
    func permission() async -> NotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func pending() async -> [ReminderNotification] { [] }
    func install(_ notification: ReminderNotification) async throws {}
    func remove(_ identifier: String) async {}
}

private final class SettingsTestCredentials: MacCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var saveCalls = 0
    var saveCount: Int { lock.withLock { saveCalls } }
    func read(reference: String, version: Int) throws -> String {
        let value = lock.withLock { values["\(reference):\(version)"] }
        guard let value else { throw MiraError(.credentialMissing, "Synthetic credentials are unavailable.") }
        return value
    }
    func save(_ secret: String, reference: String, version: Int) throws {
        lock.withLock { saveCalls += 1; values["\(reference):\(version)"] = secret }
    }
    func delete(reference: String, version: Int) throws { lock.withLock { values["\(reference):\(version)"] = nil } }
}
