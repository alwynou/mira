import Foundation
import GRDB
import MiraCore
import MiraData

extension ScaleProbe {
    static func measureArchive(_ root: URL, output: URL) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.appendingPathComponent("scale.json").path),
              fileManager.fileExists(atPath: root.appendingPathComponent("Sessions").path),
              !fileManager.fileExists(atPath: output.path)
        else { throw failure("The archive probe requires an existing corpus and a new output path.") }

        let manifest = try SessionCodec.decode(
            Manifest.self, from: Data(contentsOf: root.appendingPathComponent("scale.json")))
        guard manifest.format == format, (1...1_000).contains(manifest.sessions),
              manifest.messagesPerSession == turns * 2, manifest.textBytes == textBytes
        else { throw failure("The retained scale corpus manifest is invalid.") }

        try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
        let sourceBusinessDirectory = output.appendingPathComponent("source-business", isDirectory: true)
        try fileManager.createDirectory(at: sourceBusinessDirectory, withIntermediateDirectories: false)
        let archive = output.appendingPathComponent("archive", isDirectory: true)
        let sourceDatabaseURL = sourceBusinessDirectory.appendingPathComponent("Business.sqlite")

        let calls = ArchiveProbeCalls()
        var database: DatabaseQueue?
        var authority: SQLiteLibraryAuthority?
        var library: FileSessionLibrary?
        var business: SQLiteBusinessEffects?
        var exporter: SQLiteLibraryArchiveExporter?
        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
            let db = try DatabaseQueue(path: sourceDatabaseURL.path, configuration: configuration)
            database = db
            let a = try SQLiteLibraryAuthority(database: db)
            authority = a
            let journalStart = ContinuousClock.now
            let sessions = try FileSessionLibrary(directory: root.appendingPathComponent("Sessions"))
            library = sessions
            let journalOpen = elapsed(journalStart)
            let effects = try SQLiteBusinessEffects(
                database: db, libraryID: a.libraryID,
                resolver: JournalAgentEffectResolver(journal: sessions, payloads: sessions),
                handlers: [], validator: ScaleProbeArchiveValidator(calls: calls))
            business = effects
            let modules = [try SQLiteBusinessEffects.archiveModule()]
            let archiveExporter = try SQLiteLibraryArchiveExporter(
                database: db, sessions: sessions, libraryID: a.libraryID,
                attachmentDirectory: sourceBusinessDirectory, modules: modules,
                faultInjector: { stage in
                    if stage != .afterCatalogChunk { writeProgress("archive: export \(stage)\n") }
                })
            exporter = archiveExporter

            var originalHeads: [SessionJournalHead] = []
            var inventoryCursor: ConversationID?
            while true {
                let page = try await sessions.sessions(after: inventoryCursor, limit: 128)
                guard let last = page.last else { break }
                for id in page {
                    guard originalHeads.count < manifest.sessions,
                          id == ConversationID(identifier(2, originalHeads.count)) else {
                        throw failure("The source session inventory differs from the synthetic manifest.")
                    }
                    originalHeads.append(try await sessions.head(sessionID: id))
                }
                inventoryCursor = last
            }
            guard originalHeads.count == manifest.sessions else { throw failure("The source session inventory is incomplete.") }
            writeProgress("archive: exporting\n")
            let authorization = try await a.authorization()
            let exportStart = ContinuousClock.now
            _ = try await archiveExporter.export(to: archive, authorization: authorization)
            let export = elapsed(exportStart)

            let validateStart = ContinuousClock.now
            let validated = try await SQLiteLibraryArchiveExporter.validate(at: archive, modules: modules)
            let validate = elapsed(validateStart)
            let manifestBytes = try SessionCodec.encode(validated).count
            writeProgress("archive: validated \(validated.fileCount) files, \(manifestBytes) manifest bytes\n")

            await archiveExporter.close()
            exporter = nil
            try await effects.close()
            business = nil
            await a.close()
            authority = nil
            try await sessions.close()
            library = nil
            try db.close()
            database = nil

            let restoreStart = ContinuousClock.now
            writeProgress("archive: restoring\n")
            let restorer = try SQLiteLibraryRestorer(
                modules: modules,
                sourceFactory: { _ in
                    calls.record("factory")
                    return SQLiteLibraryRestorationSources(
                        authorizer: ScaleProbeArchiveAuthorizer(calls: calls), close: { calls.record("close") })
                }, faultInjector: { stage in writeProgress("archive: restore \(stage)\n") })
            let restoredDirectory = output.appendingPathComponent("restored", isDirectory: true)
            let result: SQLiteLibraryRestorationResult
            do {
                result = try await restorer.restore(from: archive, to: restoredDirectory)
            } catch {
                await restorer.close()
                throw error
            }
            await restorer.close()
            let restore = elapsed(restoreStart)

            let verificationStart = ContinuousClock.now
            let restoredLibrary = try FileSessionLibrary(
                directory: restoredDirectory.appendingPathComponent("Sessions"))
            do {
                let restoredHeads = try await restoredLibrary.withSnapshot { $0.sessions.map(\.head) }
                guard result.sessions == originalHeads, restoredHeads == originalHeads,
                      result.sessions.count == manifest.sessions
                else { throw failure("Restoration changed the synthetic session heads.") }

                let projection = try SQLiteSessionProjection(
                    path: restoredDirectory.appendingPathComponent("Projections/Session.sqlite").path)
                do {
                    for ordinal in 0..<manifest.sessions {
                        let sessionID = ConversationID(identifier(2, ordinal))
                        let runtime = try await JournalSessionReader(journal: restoredLibrary, payloads: restoredLibrary)
                            .snapshot(sessionID: sessionID)
                        guard runtime.state.executionOrder.count == turns,
                              runtime.state.activeExecutionID == nil,
                              runtime.state.executions.values.allSatisfy({ $0.completion?.status == .completed })
                        else { throw failure("A restored synthetic session is not completed.") }
                        let page = try await projection.messagePage(sessionID: sessionID, beforeSequence: nil, limit: 128)
                        guard page.session != nil, page.messages.count == turns * 2, !page.hasMore else {
                            throw failure("A restored projection page is incomplete.")
                        }
                        for (offset, row) in page.messages.enumerated() {
                            guard let reference = row.body, !row.bodyInvalidated,
                                  try await restoredLibrary.read(reference) == Data(
                                    body(
                                        session: ordinal, turn: turns - 1 - offset / 2,
                                        role: offset.isMultiple(of: 2) ? "assistant" : "user").utf8)
                            else { throw failure("A restored synthetic body differs from the source corpus.") }
                        }
                    }
                    try await projection.close()
                } catch {
                    try? await projection.close()
                    throw error
                }
                try await restoredLibrary.close()
            } catch {
                try? await restoredLibrary.close()
                throw error
            }
            let verification = elapsed(verificationStart)
            guard calls.snapshot() == ["factory": 1, "close": 1] else {
                throw failure("Archive restoration made unexpected operational calls or leaked source ownership.")
            }
            writeProgress("archive: verified \(manifest.sessions) sessions and \(manifest.sessions * turns * 2) bodies\n")
            try emit(
                operation: "archive", count: manifest.sessions,
                times: [
                    "journalOpen": journalOpen, "export": export,
                    "validate": validate, "restore": restore, "verification": verification,
                    "total": elapsed(journalStart),
                ], details: ["fileCount": validated.fileCount, "catalogChunks": validated.chunks.count,
                             "catalogBytes": validated.chunks.reduce(0) { $0 + $1.byteCount }, "manifestBytes": manifestBytes,
                             "verifiedVisibleBodies": manifest.sessions * turns * 2])
        } catch {
            await exporter?.close()
            try? await business?.close()
            await authority?.close()
            try? await library?.close()
            try? database?.close()
            throw error
        }
    }

    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private static func writeProgress(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

private struct ScaleProbeArchiveValidator: SQLiteBusinessAuthorizationValidator {
    let calls: ArchiveProbeCalls
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        calls.record("business")
        throw MiraError(.unsupported, "Archive measurement cannot authorize business operations.")
    }
}

private struct ScaleProbeArchiveAuthorizer: AgentSourceAuthorizer {
    let calls: ArchiveProbeCalls
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        calls.record("source")
        throw MiraError(.unauthorized, "The settled archive corpus needs no source authorization.")
    }
}

private final class ArchiveProbeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func snapshot() -> [String: Int] { lock.withLock { counts } }
}
