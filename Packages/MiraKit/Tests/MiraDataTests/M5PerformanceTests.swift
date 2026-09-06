import CryptoKit
import Darwin
import Foundation
import GRDB
import MiraCore
import Testing
@testable import MiraData

@Suite("M5 performance gates")
struct M5PerformanceTests {
    @Test("Opt-in deterministic M5 benchmark", .enabled(if: ProcessInfo.processInfo.environment["MIRA_RUN_M5_BENCHMARKS"] == "1"))
    func benchmark() throws {
        let fixture = try M5PerformanceFixture()
        defer { fixture.cleanup() }
        var metrics: [M5Metric] = []
        print("M5 fixture ready; measuring warm local operations.")

        let contextMetric = try measure(name: "memoryPrefetchAndContextBuild", targetP95Milliseconds: 300) {
            let runtimeConversations = try fixture.store.conversations(includeArchived: true)
            let runtimeWorkspaces = try fixture.store.workspaces()
            let runtimeMessages = try fixture.store.messages(in: fixture.hotConversationID)
            let runtimeExecutions = try fixture.store.executions(in: fixture.hotConversationID)
            let runtimeSuppressedIDs = try fixture.store.suppressedMemorySourceMessageIDs()
            let currentExecution = try fixture.hotExecutionValue()
            let recalled = try fixture.store.recallMemories(query: fixture.triggerText, workspaceID: fixture.hotWorkspaceID, connectionID: fixture.route.connectionID, limit: 6, at: fixture.date)
            guard !recalled.memories.isEmpty else { throw MiraError(.storage, "The M5 memory fixture returned no positive recall result.") }
            let request = try ContextBuilder.build(
                execution: currentExecution,
                conversations: runtimeConversations,
                workspaces: runtimeWorkspaces,
                messages: runtimeMessages,
                executions: runtimeExecutions,
                memories: recalled.memories,
                suppressedMessageIDs: runtimeSuppressedIDs,
                at: fixture.date
            )
            guard request.messages.last?.text == fixture.triggerText, request.contextInfo?.references.contains(where: { $0.kind == "memory" }) == true else { throw MiraError(.storage, "The M5 context fixture lost its current trigger message.") }
            return M5Observation(hits: recalled.memories.count, truncated: recalled.isTruncated, scanned: nil)
        }
        metrics.append(contextMetric)

        let knowledgeCases: [(name: String, query: String, expectsHit: Bool)] = [
            ("englishSelectivity", "section 0100", true),
            ("cjkHeading", "知识检索", true), // i18n-fixture: CJK search coverage.
            ("cjkThree", "知识检", true), // i18n-fixture: three-scalar CJK lookup.
            ("mixedCJKEnglish", "知识检索 Benchmark", true), // i18n-fixture: mixed Chinese and English query.
            ("cjkMixed", "資料検索", true), // i18n-fixture: CJK search coverage.
            ("cjkPath", "引用路径", true), // i18n-fixture: CJK search coverage.
            ("mixedCodePath", "Sources/MiraCore/Knowledge/MarkdownChunker.swift", true),
            ("escapedLiteral", "literal_%", true),
            ("emptyNegative", "absent_fixture_term", false),
            ("shortCJKNegative", "空无", false) // i18n-fixture: absent two-scalar query.
        ]
        for item in knowledgeCases {
            metrics.append(try measure(name: "knowledge_\(item.name)", targetP95Milliseconds: 500) {
                let result = try fixture.store.searchKnowledge(query: item.query, workspaceID: nil, connectionID: nil, limit: 6)
                guard (result.hits.isEmpty == !item.expectsHit) else {
                    throw MiraError(.storage, "The M5 knowledge fixture returned an unexpected semantic result.")
                }
                guard result.scannedCandidates <= 20_000 else { throw MiraError(.storage, "The M5 knowledge search exceeded its bounded candidate scan.") }
                return M5Observation(hits: result.hits.count, truncated: result.isTruncated, scanned: result.scannedCandidates)
            })
        }
        metrics.append(try measure(name: "knowledge_shortCJK", targetP95Milliseconds: 500) {
            let result = try fixture.store.searchKnowledge(query: "知识", workspaceID: nil, connectionID: nil, limit: 6) // i18n-fixture: two-scalar short-query fallback.
            guard !result.hits.isEmpty else { throw MiraError(.storage, "The M5 short CJK fixture returned no result.") }
            guard result.scannedCandidates <= 20_000 else { throw MiraError(.storage, "The M5 short CJK search exceeded its bounded candidate scan.") }
            return M5Observation(hits: result.hits.count, truncated: result.isTruncated, scanned: result.scannedCandidates)
        })

        let reopenMetric = try measure(name: "sqliteReopenProxy", targetP95Milliseconds: nil) {
            let reopened = try SQLiteMiraStore(directory: fixture.libraryDirectory)
            defer { _ = reopened }
            _ = try reopened.workspaces()
            return M5Observation(hits: 0, truncated: false, scanned: 0)
        }
        metrics.append(reopenMetric)

        let databaseBytes = try fixture.databaseBytes()
        let databaseLimitBytes: Int64 = 2 * 1024 * 1024 * 1024
        let report = M5BenchmarkReport(
            seed: M5PerformanceFixture.seed,
            memoryCount: 10_000,
            chunkCount: 50_000,
            messageCount: 100_000,
            databaseBytes: databaseBytes,
            databaseLimitBytes: databaseLimitBytes,
            databaseExceedsLimit: databaseBytes > databaseLimitBytes,
            metadata: try fixture.metadata(),
            metrics: metrics
        )
        try writeReportIfRequested(report)
        for metric in metrics {
            #expect(metric.failure == nil, "M5 operation failed for \(metric.name): \(metric.failure ?? "")")
            #expect(metric.samplesMilliseconds.count == 30, "M5 measurement did not complete 30 samples.")
            if let target = metric.targetP95Milliseconds, let p95 = metric.p95Milliseconds {
                #expect(p95 <= target, "M5 P95 target exceeded for \(metric.name): \(p95) ms")
            }
        }
        // A single complete scale backup is reliability evidence, not a latency percentile.
        let backupResult = try fixture.verifyLargeBackup()
        print("M5 scale backup round trip: \(backupResult)")
        if let path = ProcessInfo.processInfo.environment["MIRA_M5_REPORT_PATH"] {
            let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("backup.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(backupResult).write(to: url, options: .atomic)
        }
    }

    private func measure(name: String, targetP95Milliseconds: Double?, operation: () throws -> M5Observation) throws -> M5Metric {
        print("M5 metric: \(name)")
        var samples: [Double] = []
        var observations: [M5Observation] = []
        var failure: String?
        do {
            for _ in 0..<5 { _ = try operation() }
            for _ in 0..<30 {
                let start = ContinuousClock.now
                let observation = try operation()
                let duration = start.duration(to: .now).components
                samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
                observations.append(observation)
            }
        } catch { failure = MiraError.safe(error).message }
        let sorted = samples.sorted()
        return M5Metric(name: name, targetP95Milliseconds: targetP95Milliseconds,
                        samplesMilliseconds: samples,
                        p50Milliseconds: sorted.isEmpty ? nil : sorted[sorted.count / 2],
                        p95Milliseconds: sorted.isEmpty ? nil : sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
                        observations: observations, failure: failure)
    }

    private func writeReportIfRequested(_ report: M5BenchmarkReport) throws {
        guard let path = ProcessInfo.processInfo.environment["MIRA_M5_REPORT_PATH"] else { return }
        guard path.hasPrefix("/") else { throw MiraError(.invalidInput, "MIRA_M5_REPORT_PATH must be absolute.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private struct M5Metric: Encodable {
    let name: String
    let targetP95Milliseconds: Double?
    let samplesMilliseconds: [Double]
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let observations: [M5Observation]
    let failure: String?
}

private struct M5Observation: Encodable {
    let hits: Int
    let truncated: Bool
    let scanned: Int?
}

private struct M5BenchmarkReport: Encodable {
    let seed: Int
    let memoryCount: Int
    let chunkCount: Int
    let messageCount: Int
    let databaseBytes: Int64
    let databaseLimitBytes: Int64
    let databaseExceedsLimit: Bool
    let metadata: [String: String]
    let metrics: [M5Metric]
}

private struct M5PerformanceFixture {
    static let seed = 10_000
    static let sectionBytes = 4_096
    static let sectionsPerFile = 2_500
    static let fileCount = 20
    static let messageCount = 100_000
    static let conversationCount = 1_000

    let rootDirectory: URL
    let libraryDirectory: URL
    let store: SQLiteMiraStore
    let route: ResolvedModelRouteSnapshot
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let workspaces: [Workspace]
    let conversations: [Conversation]
    let hotWorkspaceID: WorkspaceID
    let hotConversationID: ConversationID
    var hotMessages: [Message] = []
    var hotExecutions: [Execution] = []
    var hotExecution: Execution?
    var triggerText: String = ""

    init() throws {
        rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-m5-\(UUID().uuidString)", isDirectory: true)
        libraryDirectory = rootDirectory.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: false)
        let fixtureRoot = rootDirectory
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: fixtureRoot) }
        }
        store = try SQLiteMiraStore(directory: libraryDirectory)

        let firstWorkspace = Workspace(id: Self.entityID(1), name: "M5 Workspace A")
        let secondWorkspace = Workspace(id: Self.entityID(2), name: "M5 Workspace B")
        try store.saveWorkspace(firstWorkspace, expectedRevision: nil)
        try store.saveWorkspace(secondWorkspace, expectedRevision: nil)
        workspaces = [firstWorkspace, secondWorkspace]
        hotWorkspaceID = firstWorkspace.id

        let connection = ProviderConnection(id: Self.connectionID(1), name: "M5 Fixture Connection", providerKind: .openAICompatible, baseURL: "https://example.invalid", credentialReference: "m5-fixture")
        let model = ModelDescriptor(id: Self.modelID(1), connectionID: connection.id, modelID: "m5-fixture", contextWindow: 32_768, textCapability: .declared)
        let preset = ModelRoute(id: Self.routeID(1), name: "M5 Fixture Route", modelDescriptorID: model.id, maxOutputTokens: 1_024)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.saveModel(model, expectedRevision: nil)
        try store.saveRoute(preset, expectedRevision: nil)
        route = ResolvedModelRouteSnapshot(route: preset, model: model, connection: connection, purpose: .conversation, selection: .global)

        var builtConversations: [Conversation] = []
        builtConversations.reserveCapacity(Self.conversationCount)
        for index in 0..<Self.conversationCount {
            let workspaceID = index.isMultiple(of: 2) ? firstWorkspace.id : secondWorkspace.id
            let conversation = Conversation(id: Self.conversationID(index), workspaceID: workspaceID, title: "", createdAt: date, updatedAt: date)
            try store.createConversation(conversation)
            builtConversations.append(conversation)
        }
        conversations = builtConversations
        hotConversationID = builtConversations[0].id
        print("M5 fixture: seeding messages and memories.")
        try seedMessagesAndExecutions()
        try seedMemories()
        print("M5 fixture: importing 20 Markdown files.")
        try importMarkdownSources()
        try store.pool.read { db in
            try SQLiteMiraStore.validateContents(in: db)
            let messages = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
            let executions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM executions") ?? 0
            let memories = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0
            let chunks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_chunks") ?? 0
            guard messages == Self.messageCount, executions == 50_001, memories == 10_000, chunks == 50_000 else {
                throw MiraError(.storage, "The M5 fixture row counts are not the requested deterministic dataset.")
            }
        }
        hotMessages = try store.messages(in: conversations[0].id)
        hotExecutions = try store.executions(in: conversations[0].id)
        guard let current = hotExecutions.first(where: { $0.status == .queued }),
              let trigger = hotMessages.first(where: { $0.id == current.triggerMessageID }) else {
            throw MiraError(.storage, "The M5 hot conversation fixture is incomplete.")
        }
        hotExecution = current
        triggerText = trigger.text
        completed = true
    }

    func verifyLargeBackup() throws -> [String: Double] {
        let backup = rootDirectory.appendingPathComponent("scale-backup.bundle")
        let restoredDirectory = rootDirectory.appendingPathComponent("scale-restored")
        print("M5 scale backup: exporting.")
        let exportStart = ContinuousClock.now
        try store.exportBackup(to: backup)
        let exportDuration = exportStart.duration(to: .now).components
        let original = try BackupFileIO.inspect(backup.appendingPathComponent("Mira.sqlite"), limit: 2 * 1024 * 1024 * 1024)
        print("M5 scale backup: restoring.")
        let restoreStart = ContinuousClock.now
        try store.restoreBackup(from: backup, to: restoredDirectory)
        let restoreDuration = restoreStart.duration(to: .now).components
        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        try restored.pool.read { db in
            for (table, expected) in [("memories", 10_000), ("messages", 100_000), ("source_chunks", 50_000), ("executions", 50_001)] {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == expected else {
                    throw MiraError(.storage, "The M5 scale restore lost canonical rows.")
                }
            }
        }
        guard try BackupFileIO.inspect(backup.appendingPathComponent("Mira.sqlite"), limit: 2 * 1024 * 1024 * 1024) == original,
              try restored.memoryCapturePolicy().mode == .manualOnly else {
            throw MiraError(.storage, "The M5 scale restore changed its source backup or enabled capture.")
        }
        return ["databaseBytes": Double(original.byteCount),
                "exportMilliseconds": Double(exportDuration.seconds) * 1_000 + Double(exportDuration.attoseconds) / 1e15,
                "restoreMilliseconds": Double(restoreDuration.seconds) * 1_000 + Double(restoreDuration.attoseconds) / 1e15]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func databaseBytes() throws -> Int64 {
        try store.pool.read { db in
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return pages * size
        }
    }

    func hotExecutionValue() throws -> Execution {
        guard let hotExecution else { throw MiraError(.storage, "The M5 hot execution is unavailable.") }
        return hotExecution
    }

    func metadata() throws -> [String: String] {
        let process = ProcessInfo.processInfo
        var values: [String: String] = [
            "os": process.operatingSystemVersionString,
            "processorCount": String(process.processorCount),
            "physicalMemory": String(process.physicalMemory),
            "swift": "Swift 6 package test",
            "fixtureVersion": "m5-scale-v1",
            "cacheMode": "Five warmups, then 30 samples; no OS cache purge"
        ]
        if let model = Self.sysctlString("hw.model") { values["hardwareModel"] = model }
        if let cpu = Self.sysctlString("machdep.cpu.brand_string") { values["cpu"] = cpu }
        let capability = (try? store.pool.read { db in try db.tableExists("knowledge_trigrams") }) ?? false
        values["sqliteTrigram"] = capability ? "true" : "false"
        values["sqliteVersion"] = try store.pool.read { try String.fetchOne($0, sql: "SELECT sqlite_version()") ?? "unknown" }
        values["databaseLimit"] = "2147483648 bytes"
        values["knowledgeShortCJKInternalTarget"] = "200 ms; end-to-end metric includes adapter overhead"
        values["markdownFileBytes"] = "10240000 each; min=max"
        values["markdownChunkBytes"] = "4096 each; min=max; parser verified"
        let distributions = try store.pool.read { db -> [String: String] in
            func distribution(table: String, column: String) throws -> String {
                let minimum = try Int.fetchOne(db, sql: "SELECT MIN(length(CAST(\(column) AS BLOB))) FROM \(table)") ?? 0
                let maximum = try Int.fetchOne(db, sql: "SELECT MAX(length(CAST(\(column) AS BLOB))) FROM \(table)") ?? 0
                let total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(CAST(\(column) AS BLOB))), 0) FROM \(table)") ?? 0
                return "min=\(minimum),max=\(maximum),total=\(total)"
            }
            return [
                "messageBytes": try distribution(table: "messages", column: "text"),
                "memoryBytes": try distribution(table: "memory_search", column: "content"),
                "chunkBytes": try distribution(table: "source_chunks", column: "text")
            ]
        }
        values.merge(distributions, uniquingKeysWith: { _, new in new })
        return values
    }

    private func seedMessagesAndExecutions() throws {
        let routeJSON = try SQLiteMiraStore.encode(route)
        try store.pool.write { db in
            for conversationIndex in 0..<Self.conversationCount {
                let pairCount = conversationIndex == 0 ? 49 : 50
                for pair in 0..<pairCount {
                    let executionID = Self.executionID(conversationIndex, pair)
                    let userID = Self.userMessageID(conversationIndex, pair)
                    let assistantID = Self.assistantMessageID(conversationIndex, pair)
                    let userText = Self.messageText(conversationIndex, pair, role: "user")
                    let created = date.addingTimeInterval(Double(conversationIndex * 100 + pair))
                    try db.execute(sql: "INSERT INTO executions (id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at) VALUES (?, ?, ?, NULL, 'completed', ?, NULL, NULL, NULL, ?, ?)", arguments: [SQLiteMiraStore.id(executionID), SQLiteMiraStore.id(conversations[conversationIndex].id), SQLiteMiraStore.id(userID), routeJSON, created.timeIntervalSince1970, created.timeIntervalSince1970])
                    try insertMessage(db, id: userID, conversationID: conversations[conversationIndex].id, executionID: executionID, sequence: pair * 2 + 1, role: "user", text: userText, createdAt: created)
                    try insertMessage(db, id: assistantID, conversationID: conversations[conversationIndex].id, executionID: executionID, sequence: pair * 2 + 2, role: "assistant", text: "M5 assistant reply \(conversationIndex)-\(pair)", createdAt: created.addingTimeInterval(0.1))
                }
                if conversationIndex == 0 {
                    let failedExecution = Self.executionID(conversationIndex, 49)
                    let failedUser = Self.userMessageID(conversationIndex, 49)
                    let failedCreated = date.addingTimeInterval(4_900)
                    try db.execute(sql: "INSERT INTO executions (id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at) VALUES (?, ?, ?, NULL, 'failed', ?, NULL, NULL, NULL, ?, ?)", arguments: [SQLiteMiraStore.id(failedExecution), SQLiteMiraStore.id(conversations[0].id), SQLiteMiraStore.id(failedUser), routeJSON, failedCreated.timeIntervalSince1970, failedCreated.timeIntervalSince1970])
                    try insertMessage(db, id: failedUser, conversationID: conversations[0].id, executionID: failedExecution, sequence: 99, role: "user", text: Self.messageText(0, 49, role: "user"), createdAt: failedCreated)

                    let currentExecution = Self.executionID(conversationIndex, 50)
                    let trigger = Self.userMessageID(conversationIndex, 50)
                    let currentCreated = date.addingTimeInterval(5_000)
                    try db.execute(sql: "INSERT INTO executions (id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at) VALUES (?, ?, ?, NULL, 'queued', ?, NULL, NULL, NULL, ?, ?)", arguments: [SQLiteMiraStore.id(currentExecution), SQLiteMiraStore.id(conversations[0].id), SQLiteMiraStore.id(trigger), routeJSON, currentCreated.timeIntervalSince1970, currentCreated.timeIntervalSince1970])
                    try insertMessage(db, id: trigger, conversationID: conversations[0].id, executionID: currentExecution, sequence: 100, role: "user", text: "M5 memory preference query", createdAt: currentCreated)
                }
            }
        }
    }

    private func seedMemories() throws {
        try store.pool.write { db in
            for index in 0..<10_000 {
                let conversationIndex = index % Self.conversationCount
                let pair = index % (conversationIndex == 0 ? 49 : 50)
                let sourceID = Self.userMessageID(conversationIndex, pair)
                let scope: MemoryScope = index.isMultiple(of: 3) ? .global : .workspace(conversations[conversationIndex].workspaceID!)
                let allowed: Set<ConnectionID>? = index.isMultiple(of: 37) ? [] : (index.isMultiple(of: 11) ? [route.connectionID] : nil)
                let validFrom: Date? = index.isMultiple(of: 7) ? date.addingTimeInterval(-10_000) : (index.isMultiple(of: 29) ? date.addingTimeInterval(10_000) : nil)
                let validUntil: Date? = index.isMultiple(of: 13) ? date.addingTimeInterval(index.isMultiple(of: 29) ? 20_000 : 10_000) : (index.isMultiple(of: 31) && !index.isMultiple(of: 29) ? date.addingTimeInterval(-1) : nil)
                let draft = MemoryDraft(content: "M5 memory preference \(index) for deterministic retrieval", scope: scope, kind: index.isMultiple(of: 5) ? .preference : .fact, allowsRemoteUse: !index.isMultiple(of: 17), allowedConnectionIDs: allowed, validFrom: validFrom, validUntil: validUntil)
                let sourceText = Self.messageText(conversationIndex, pair, role: "user")
                try draft.validate()
                try store.validateMemoryScope(scope, in: db)
                let memoryID = Self.memoryID(index)
                let memory = Memory(id: memoryID, draft: draft, scope: scope, subject: .user, state: .active, origin: .explicitUser, authority: .explicitUser, revision: 1, createdAt: date, updatedAt: date)
                try store.insertMemory(memory, sourceKind: .message, sourceID: sourceID.rawValue, assertionHash: store.memoryHash(draft.content), in: db)
                let evidence = MemoryEvidence(id: Self.deterministicUUID(index, salt: 10), memoryID: memoryID, sourceKind: .message, sourceID: sourceID.rawValue, sourceRevision: 1, conversationID: conversations[conversationIndex].id, excerpt: sourceText, sourceHash: store.memoryPayloadHashString(sourceText), speakerRole: .user, createdAt: date)
                try store.insertMemoryEvidence(evidence, in: db)
                try store.insertMemoryRevision(MemoryRevision(memoryID: memoryID, revision: 1, draft: draft, changedAt: date), in: db)
                try store.indexMemory(memory, in: db)
                try store.persistMemoryUsages([MemoryUsage(memoryID: memoryID, revision: 1)], executionID: Self.executionID(conversationIndex, pair), at: date, kind: .capture, in: db)
            }
        }
        let memories = try store.memoryList(workspaceID: nil, states: [.active], query: "M5 memory", limit: 2).memories
        if let candidate = memories.first { _ = try store.changeMemoryState(candidate.id, workspaceID: nil, state: .candidate, expectedRevision: candidate.revision, at: date) }
        if let archived = memories.dropFirst().first { _ = try store.changeMemoryState(archived.id, workspaceID: nil, state: .archived, expectedRevision: archived.revision, at: date) }
    }

    private func importMarkdownSources() throws {
        for fileIndex in 0..<Self.fileCount {
            print("M5 import: file \(fileIndex + 1)/20")
            let file = rootDirectory.appendingPathComponent("m5-source-\(fileIndex).md")
            var data = Data(); data.reserveCapacity(Self.sectionBytes * Self.sectionsPerFile)
            for section in 0..<Self.sectionsPerFile {
                let heading = "# M5 File \(fileIndex) Section \(String(format: "%04d", section))\n"
                var prefix = "Benchmark fixture body for deterministic local knowledge search. "
                if fileIndex == 0 { prefix += "\u{77E5}\u{8BC6}\u{68C0}\u{7D22} \u{5F15}\u{7528}\u{8DEF}\u{5F84} " } // i18n-fixture: CJK search text.
                if fileIndex == 1 { prefix += "\u{8CC7}\u{6599}\u{691C}\u{7D22} " } // i18n-fixture: CJK search text.
                if fileIndex == 2 { prefix += "Sources/MiraCore/Knowledge/MarkdownChunker.swift " }
                if fileIndex == 3 { prefix += "literal_% OR \"quoted\" " }
                let fixed = heading + prefix
                let fillerBytes = Self.sectionBytes - fixed.utf8.count - 1
                guard fillerBytes > 0 else { throw MiraError(.storage, "The M5 Markdown section fixture is too large.") }
                data.append(contentsOf: fixed.utf8)
                data.append(contentsOf: String(repeating: "x", count: fillerBytes).utf8)
                data.append(0x0A)
            }
            let slices = try MarkdownChunker.chunk(data)
            guard slices.count == Self.sectionsPerFile, slices.allSatisfy({ $0.text.utf8.count == Self.sectionBytes }) else {
                throw MiraError(.storage, "The M5 Markdown fixture did not produce the requested parser chunk count.")
            }
            try data.write(to: file, options: .atomic)
            _ = try store.importMarkdownFile(file, workspaceID: nil, updating: nil, expectedRevision: nil, at: date.addingTimeInterval(Double(fileIndex)))
        }
    }

    private func insertMessage(_ db: Database, id: MessageID, conversationID: ConversationID, executionID: ExecutionID, sequence: Int, role: String, text: String, createdAt: Date) throws {
        try db.execute(sql: "INSERT INTO messages (id, conversation_id, execution_id, sequence, role, status, text, trace_json, body_purged_at, created_at) VALUES (?, ?, ?, ?, ?, 'committed', ?, '[]', NULL, ?)", arguments: [SQLiteMiraStore.id(id), SQLiteMiraStore.id(conversationID), SQLiteMiraStore.id(executionID), sequence, role, text, createdAt.timeIntervalSince1970])
    }

    private static func messageText(_ conversation: Int, _ pair: Int, role: String) -> String { "M5 \(role) message \(conversation)-\(pair)" }
    private static func entityID(_ value: Int) -> WorkspaceID { .init(deterministicUUID(value, salt: 1)) }
    private static func conversationID(_ value: Int) -> ConversationID { .init(deterministicUUID(value, salt: 2)) }
    private static func connectionID(_ value: Int) -> ConnectionID { .init(deterministicUUID(value, salt: 3)) }
    private static func modelID(_ value: Int) -> ModelDescriptorID { .init(deterministicUUID(value, salt: 4)) }
    private static func routeID(_ value: Int) -> RouteID { .init(deterministicUUID(value, salt: 5)) }
    private static func executionID(_ conversation: Int, _ pair: Int) -> ExecutionID { .init(deterministicUUID(conversation * 100 + pair, salt: 6)) }
    private static func userMessageID(_ conversation: Int, _ pair: Int) -> MessageID { .init(deterministicUUID(conversation * 100 + pair, salt: 7)) }
    private static func assistantMessageID(_ conversation: Int, _ pair: Int) -> MessageID { .init(deterministicUUID(conversation * 100 + pair, salt: 8)) }
    private static func memoryID(_ value: Int) -> MemoryID { .init(deterministicUUID(value, salt: 11)) }
    private static func deterministicUUID(_ value: Int, salt: Int) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("m5:\(seed):\(salt):\(value)".utf8)).prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(13).prefix(3))-8\(hex.dropFirst(16).prefix(3))-\(hex.dropFirst(19).prefix(12))")!
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
