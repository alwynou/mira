import Foundation
import MiraCore
import MiraData
import Testing

@Suite("macOS library diagnostics", .timeLimit(.minutes(1)))
struct MacLibraryDiagnosticsTests {
    @Test func reportsTheLinkedSQLiteEngineAndCanBeRepeatedWithoutSchemaChanges() async throws {
        try await withDirectory { directory in
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(),
                credentials: CompositionCredentials(), modules: { _ in [] })
            do {
                let first = try await library.diagnostics()
                let second = try await library.diagnostics()
                #expect(!first.sqliteVersion.isEmpty)
                #expect(first.supportsFTS5)
                #expect(first.supportsTrigram)
                #expect(second == first)
                #expect(await library.status().phase == .ready)
                #expect(await library.close().isSettled)
                let reopened = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                do {
                    #expect(try await reopened.diagnostics() == first)
                    #expect(await reopened.close().isSettled)
                } catch {
                    _ = await reopened.close()
                    throw error
                }
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func diagnosticsRequiresReadyAccessAndSurvivesACompletedMaintenanceGeneration() async throws {
        try await withDirectory { directory in
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(),
                credentials: CompositionCredentials(), modules: { _ in [] })
            do {
                let request = AgentLibraryMaintenanceRequest(
                    id: UUID(), namespace: "knowledge.collect", revision: 1,
                    scope: .library, requestedAt: Date())
                _ = try await library.maintain(request)
                let diagnostics = try await library.diagnostics()
                #expect(!diagnostics.sqliteVersion.isEmpty)
                #expect(await library.status().phase == .ready)
                #expect(await library.close().isSettled)
                await #expect(throws: MiraError.self) {
                    _ = try await library.diagnostics()
                }
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }
}
