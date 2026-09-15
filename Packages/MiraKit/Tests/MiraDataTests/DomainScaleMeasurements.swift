import Darwin
import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

/// Opt-in domain scale measurement. This is deliberately skipped in ordinary test runs because it
/// creates roughly 10,000 memories and 50,000 Markdown chunks through the public mutation APIs.
@Suite("Domain scale measurements", .serialized, .timeLimit(.minutes(30)))
struct DomainScaleMeasurements {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRA_MEASURE_DOMAIN_SCALE"] == "1"))
    func measureMemoryAndKnowledgeRetrievalAtDomainScale() async throws {
        let fixture = try await DomainScaleFixture.open()
        do {
            let seed = try await fixture.seed()
            let request = AgentContextRequest(
                sessionID: .init(), executionID: .init(), workspaceID: nil,
                userText: "domain scale measurement", authorizationEpoch: 0, destination: .local)

            let queries = [
                ("english", "scale marker"),
                // Chinese search fixtures are intentional documented Unicode coverage.
                ("chinese2", "茶叶"), ("chinese3", "绿茶叶"),  // i18n-fixture: Chinese scalar-length queries.
                ("title", "scale-document-07"), ("mixed", "混合 scale"),  // i18n-fixture: Chinese-English mixed query with broad partial matches.
                ("code", "src/Mira/Agent.swift"), ("escaped", "quoted \"literal\""),
                ("negative", "term-that-does-not-exist"),
            ]

            var samples: [[String: Any]] = []
            for query in queries {
                for _ in 0..<5 {
                    _ = try await fixture.searchMemory(query.1, request: request)
                    _ = try await fixture.searchKnowledge(query.1)
                }
                for sample in 0..<30 {
                    let memoryStart = ContinuousClock.now
                    let memory = try await fixture.searchMemory(query.1, request: request)
                    let memoryElapsed = memoryStart.duration(to: .now)
                    let knowledgeStart = ContinuousClock.now
                    let knowledge = try await fixture.searchKnowledge(query.1)
                    let knowledgeElapsed = knowledgeStart.duration(to: .now)
                    let authorizationStart = ContinuousClock.now
                    try await fixture.authorize(memory: memory, knowledge: knowledge, request: request)
                    let authorizationElapsed = authorizationStart.duration(to: .now)

                    let memoryMatches =
                        query.0 == "negative" ? memory.memories.isEmpty : fixture.memoryHit(memory, class: query.0)
                    let knowledgeMatches =
                        query.0 == "negative" ? knowledge.hits.isEmpty : fixture.knowledgeHit(knowledge, class: query.0)
                    #expect(memoryMatches, Comment(rawValue: "Memory query class: \(query.0)"))
                    #expect(knowledgeMatches, Comment(rawValue: "Knowledge query class: \(query.0)"))
                    #expect(knowledge.scannedCandidates <= 20_000)
                    samples.append([
                        "sample": sample, "queryClass": query.0,
                        "memoryMs": DomainScaleFixture.milliseconds(memoryElapsed),
                        "knowledgeMs": DomainScaleFixture.milliseconds(knowledgeElapsed),
                        "authorizationMs": DomainScaleFixture.milliseconds(authorizationElapsed),
                        "memoryReturnedHits": memory.memories.count,
                        "knowledgeReturnedHits": knowledge.hits.count,
                        "knowledgeScannedCandidates": knowledge.scannedCandidates,
                        "memoryIsTruncated": memory.isTruncated,
                        "memoryMatchesExpected": memoryMatches,
                        "knowledgeMatchesExpected": knowledgeMatches,
                        "knowledgeIsTruncated": knowledge.isTruncated,
                        "timestamp": Date().timeIntervalSince1970,
                    ])
                }
            }

            let counts = try await fixture.counts()
            #expect(counts.memoryRows == 10_000)
            #expect(counts.knowledgeFiles == 20)
            #expect(counts.knowledgeChunks == 50_000)
            var usage = rusage()
            #expect(getrusage(RUSAGE_SELF, &usage) == 0)
            var percentiles: [String: [String: Double]] = [:]
            for query in queries {
                let group = samples.filter { $0["queryClass"] as? String == query.0 }
                var values: [String: Double] = [:]
                for field in ["memoryMs", "knowledgeMs", "authorizationMs"] {
                    let sorted = group.map { $0[field] as! Double }.sorted()
                    values[field] = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
                }
                #expect(values["knowledgeMs", default: .infinity] <= 500, Comment(rawValue: query.0))
                percentiles[query.0] = values
            }
            let report: [String: Any] = [
                "memoryRows": counts.memoryRows, "knowledgeFiles": counts.knowledgeFiles,
                "knowledgeChunks": counts.knowledgeChunks, "databaseBytes": counts.databaseBytes,
                "knowledgeBytes": counts.knowledgeBytes, "samples": samples,
                "p95Milliseconds": percentiles,
                "peakRSSBytesIncludingSeed": usage.ru_maxrss,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "scope": "global/local", "authorization": "validated returned source references",
                "assembler": "retrieval returned hits measured; full runtime context assembly excluded",
                "seedMemoryRows": seed.memoryRows, "seedKnowledgeChunks": seed.knowledgeChunks,
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}

private struct DomainScaleFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let workspaces: SQLiteWorkspaceStore
    let memory: SQLiteMemoryStore
    let knowledge: SQLiteKnowledgeStore
    let authorization: AgentLibraryAuthorization
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func open() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-domain-scale-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
        let database = try DatabaseQueue(
            path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
        do {
            let authority = try SQLiteLibraryAuthority(
                database: database,
                validators: [SQLiteMemoryStore.maintenanceValidator] + SQLiteKnowledgeStore.maintenanceValidators)
            let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
            let memory = try SQLiteMemoryStore(database: database, libraryID: authority.libraryID)
            let knowledge = try SQLiteKnowledgeStore(
                database: database, libraryID: authority.libraryID,
                directory: directory.appendingPathComponent("knowledge"))
            return .init(
                directory: directory, database: database, authority: authority, workspaces: workspaces,
                memory: memory, knowledge: knowledge, authorization: try await authority.authorization())
        } catch {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func seed() async throws -> (memoryRows: Int, knowledgeChunks: Int) {
        for index in 0..<10_000 {
            let content: String
            switch index % 5 {
            case 0: content = "scale marker scale-document-07 memory \(index)"
            case 1: content = "茶叶 preference scale \(index)"  // i18n-fixture: Chinese two-scalar memory fixture.
            case 2: content = "绿茶叶 mixed scale \(index)"  // i18n-fixture: Chinese three-scalar memory fixture.
            case 3: content = "src/Mira/Agent.swift code path \(index)"
            default: content = "quoted \"literal\" 混合 scale \(index)"  // i18n-fixture: Chinese-English mixed memory fixture.
            }
            _ = try await memory.createMemory(
                draft: .init(content: content, scope: .global),
                source: .manualEntry(id: UUID(), statement: content), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: date)
            if index % 1_000 == 999 {
                FileHandle.standardError.write(Data("Domain scale: seeded memory \(index + 1)/10000\n".utf8))
            }
        }
        for file in 0..<20 {
            let bytes = makeMarkdown(file: file)
            let slices = try MarkdownChunker.chunk(bytes)
            guard bytes.count == 10_240_000, slices.count == 2_500,
                slices.allSatisfy({ $0.text.utf8.count == 4_096 })
            else {
                throw MiraError(.storage, "The scale Markdown fixture did not produce 2,500 exact 4 KiB chunks.")
            }
            _ = try await knowledge.importMarkdown(
                .init(title: "scale-document-\(String(format: "%02d", file)).md", bytes: bytes),
                workspaceID: nil, updating: nil, expectedRevision: nil, operationID: UUID(),
                authorization: authorization, at: date)
            FileHandle.standardError.write(Data("Domain scale: imported Markdown file \(file + 1)/20\n".utf8))
        }
        let totals = try await counts()
        return (totals.memoryRows, totals.knowledgeChunks)
    }

    func searchMemory(_ query: String, request: AgentContextRequest) async throws -> MemorySearchResult {
        try await memory.recallMemories(query: query, request: request, limit: 6, at: date)
    }

    func searchKnowledge(_ query: String) async throws -> KnowledgeSearchResult {
        try await knowledge.searchKnowledge(query: query, scope: .init(workspaceID: nil, destination: .local), limit: 6)
    }

    func memoryHit(_ result: MemorySearchResult, class kind: String) -> Bool {
        let marker: String
        switch kind {
        case "english": marker = "scale marker"
        case "chinese2": marker = "茶叶"  // i18n-fixture: Chinese two-scalar search fixture.
        case "chinese3": marker = "绿茶叶"  // i18n-fixture: Chinese three-scalar search fixture.
        case "title": marker = "scale-document-07"
        case "mixed": marker = "混合 scale"  // i18n-fixture: Chinese-English mixed search fixture.
        case "code": marker = "src/Mira/Agent.swift"
        case "escaped": marker = "quoted \"literal\""
        default: return false
        }
        return result.memories.contains { $0.draft?.content.contains(marker) == true }
    }

    func knowledgeHit(_ result: KnowledgeSearchResult, class kind: String) -> Bool {
        if kind == "title" { return result.hits.contains { $0.source.title.contains("scale-document-07") } }
        let marker: String
        switch kind {
        case "english": marker = "scale marker"
        case "chinese2": marker = "茶叶"  // i18n-fixture: Chinese two-scalar search fixture.
        case "chinese3": marker = "绿茶叶"  // i18n-fixture: Chinese three-scalar search fixture.
        case "mixed": marker = "混合 scale"  // i18n-fixture: Chinese-English mixed search fixture.
        case "code": marker = "src/Mira/Agent.swift"
        case "escaped": marker = "quoted \"literal\""
        default: return false
        }
        return result.hits.contains { $0.snippet.contains(marker) }
    }

    func authorize(memory: MemorySearchResult, knowledge: KnowledgeSearchResult, request: AgentContextRequest)
        async throws
    {
        let memorySources = memory.memories.map {
            AgentSourceReference.domain(namespace: "memories", id: $0.id.rawValue, revision: $0.revision)
        }
        try await self.memory.validateMemorySources(memorySources, for: request, at: date)
        let knowledgeSources = knowledge.hits.map { KnowledgeSources.chunk($0.chunk) }
        try await self.knowledge.validateKnowledgeSources(knowledgeSources, for: request)
    }

    func counts() async throws -> (
        memoryRows: Int, knowledgeFiles: Int, knowledgeChunks: Int, databaseBytes: Int, knowledgeBytes: Int
    ) {
        let rows = try await database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_records") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM knowledge_sources") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM knowledge_chunks") ?? 0
            )
        }
        return (
            rows.0, rows.1, rows.2, fileBytes(directory.appendingPathComponent("business.sqlite")),
            directorySize(directory.appendingPathComponent("knowledge"))
        )
    }

    func close() async {
        await knowledge.close()
        await memory.close()
        await workspaces.close()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func makeMarkdown(file: Int) -> Data {
        var text = ""
        let prefix = "scale marker 中文茶叶绿茶叶 混合 scale src/Mira/Agent.swift quoted \"literal\" file=\(file) "  // i18n-fixture: Chinese search corpus markers.
        let prefixBytes = prefix.data(using: .utf8)!
        let filler = String(repeating: "x", count: 4_096 - prefixBytes.count - 1)
        let line = prefix + filler + "\n"
        precondition(line.utf8.count == 4_096)
        for _ in 0..<2_500 {
            text += line
        }
        return Data(text.utf8)
    }

    private func fileBytes(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    private func directorySize(_ url: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.compactMap { value -> Int? in
            guard let url = value as? URL else { return nil }
            return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }.reduce(0, +)
    }
}
