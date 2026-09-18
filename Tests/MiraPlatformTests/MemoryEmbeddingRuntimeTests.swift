import Foundation
import GRDB
import MiraCore
import MiraData
import MiraProviders
import Testing

/// Real-model acceptance is intentionally opt-in. The model directory must be a
/// locally prepared Qwen installation; this suite never downloads or contacts a
/// provider endpoint.
@Suite("Local memory embedding relevance", .serialized)
struct MemoryEmbeddingRuntimeTests {
    private struct Fixture {
        let id: String
        let content: String
    }

    private struct QueryCase {
        let id: String
        let query: String
        let expected: String?
        let alternates: [String]
        let forbidden: [String]
        let provesLexicalMiss: Bool
        let expectsEmpty: Bool
        let expectsTop: Bool
        let knownModelLimitation: Bool

        init(_ id: String, _ query: String, expected: String? = nil,
             alternates: [String] = [],
             forbidden: [String] = [], provesLexicalMiss: Bool = false,
             expectsEmpty: Bool = false, expectsTop: Bool = false, knownModelLimitation: Bool = false) {
            self.id = id
            self.query = query
            self.expected = expected
            self.alternates = alternates
            self.forbidden = forbidden
            self.provesLexicalMiss = provesLexicalMiss
            self.expectsEmpty = expectsEmpty
            self.expectsTop = expectsTop
            self.knownModelLimitation = knownModelLimitation
        }
    }

    @Test(
        "Qwen recall covers paraphrases, bilingual queries, distractors, and lexical misses",
        .enabled(if: ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"]?.isEmpty == false)
    )
    func qwenRecallAgainstLexicalBaseline() async throws {
        let rawDirectory = try #require(ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"])
        let modelDirectory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        try MacMemoryEmbeddingInstaller.validate(directory: modelDirectory)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-MemoryEmbeddingAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let databaseURL = temporaryDirectory.appendingPathComponent("Business.sqlite")
        let database = try DatabaseQueue(path: databaseURL.path)
        let authority = try SQLiteLibraryAuthority(
            database: database,
            validators: [SQLiteMemoryStore.maintenanceValidator]
        )
        let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
        let service = MacMemoryEmbeddingService(directory: modelDirectory)
        var semanticStore: SQLiteMemoryStore?
        var lexicalStore: SQLiteMemoryStore?

        do {
            semanticStore = try SQLiteMemoryStore(
                database: database,
                libraryID: authority.libraryID,
                embeddings: service
            )
            // The same database and library identity make this a production lexical
            // path over the exact indexed records; nil embeddings disables only the
            // semantic branch and does not rebuild the Qwen index.
            lexicalStore = try SQLiteMemoryStore(database: database, libraryID: authority.libraryID)
            guard let store = semanticStore, let lexicalStore else {
                throw MiraError(.storage, "Memory acceptance stores were not initialized.")
            }

            // One prepared service is shared by indexing and all recall queries.
            try await service.prepare()
            #expect(await service.status() == .ready)

            let authorization = try await authority.authorization()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let fixtures = Self.fixtures
            var memories: [String: Memory] = [:]
            var vectorsByMemoryID: [String: [Float]] = [:]
            for fixture in fixtures {
                let receipt = try await store.createMemory(
                    draft: .init(content: fixture.content, scope: .global, allowsRemoteUse: true),
                    source: .manualEntry(id: UUID(), statement: fixture.content),
                    operationID: UUID(),
                    replacing: nil,
                    expectedRevision: nil,
                    authorization: authorization,
                    at: now
                )
                memories[fixture.id] = receipt.memory
            }

            // Exercise the same durable queue used by maintenance. No vectors are
            // inserted directly into SQLite, and no production threshold is tuned.
            var indexedCount = 0
            while true {
                let jobs = try await store.pendingMemoryIndexJobs(limit: 4)
                if jobs.isEmpty { break }
                let vectors = try await service.embed(.documents(jobs.map(\.content)))
                #expect(vectors.count == jobs.count)
                for (job, vector) in zip(jobs, vectors) {
                    #expect(vector.count == MemoryEmbeddingIdentity.qwen3FourBit.dimensions)
                    #expect(vector.allSatisfy { $0.isFinite })
                    #expect(abs(Self.vectorNorm(vector) - 1) < 0.000_01)
                    #expect(try await store.completeMemoryIndexJob(
                        job,
                        vector: vector,
                        authorization: authorization
                    ))
                    vectorsByMemoryID[job.memoryID.rawValue.uuidString.lowercased()] = vector
                    indexedCount += 1
                }
            }
            #expect(indexedCount == fixtures.count)
            #expect(try await store.pendingMemoryIndexJobs(limit: 4).isEmpty)

            var lexicalMisses = 0
            var emptyNegatives = 0

            for item in Self.queries {
                let request = AgentContextRequest(
                    sessionID: .init(),
                    executionID: .init(),
                    workspaceID: nil,
                    userText: item.query,
                    authorizationEpoch: 0,
                    destination: .local
                )
                let hybrid = try await store.recallMemories(
                    query: item.query,
                    request: request,
                    limit: 3,
                    at: now
                )
                let lexical = try await lexicalStore.recallMemories(
                    query: item.query,
                    request: request,
                    limit: 3,
                    at: now
                )
                let hybridIDs = hybrid.memories.compactMap { memory in
                    memories.first(where: { $0.value.id == memory.id })?.key
                }
                let lexicalIDs = lexical.memories.compactMap { memory in
                    memories.first(where: { $0.value.id == memory.id })?.key
                }
                let queryVector = try await service.embed(.query(item.query)).first ?? []
                let neighbors = memories.compactMap { fixtureID, memory -> (String, Float)? in
                    guard let stored = vectorsByMemoryID[memory.id.rawValue.uuidString.lowercased()] else { return nil }
                    return (fixtureID, Self.cosine(queryVector, stored))
                }
                .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1 }
                .prefix(3)
                let scoreText = neighbors.map { "\($0.0)=\(String(format: "%.4f", $0.1))" }.joined(separator: ",")
                print(
                    "Memory embedding fixture \(item.id): " +
                        "hybrid=\(hybridIDs) lexical=\(lexicalIDs) " +
                        "top=\(hybridIDs.first ?? "none") scores=[\(scoreText)]"
                )

                #expect(hybrid.retrieval == .hybrid)
                #expect(lexical.retrieval == .lexical)
                if let expected = item.expected {
                    let expectedIDs = [expected] + item.alternates
                    let expectedMemories = try expectedIDs.map { try #require(memories[$0]) }
                    if item.knownModelLimitation {
                        withKnownIssue("Pinned Qwen 0.6B confuses the broad Chinese communication-style query with commuting; retained in MEMORY_SEMANTIC_FIXTURES.md, not counted as a successful recall.") {
                            #expect(hybrid.memories.contains { memory in expectedMemories.contains { $0.id == memory.id } })
                        }
                    } else {
                        #expect(hybrid.memories.contains { memory in expectedMemories.contains { $0.id == memory.id } })
                    }
                    if item.expectsTop {
                        #expect(hybrid.memories.first.map { memory in expectedMemories.contains { $0.id == memory.id } } == true)
                    }
                }
                for forbidden in item.forbidden {
                    let forbiddenMemory = try #require(memories[forbidden])
                    #expect(!hybrid.memories.contains { $0.id == forbiddenMemory.id })
                }
                if item.expectsEmpty {
                    #expect(hybrid.memories.isEmpty, "Unrelated query \(item.id) returned a memory.")
                    emptyNegatives += hybrid.memories.isEmpty ? 1 : 0
                }
                if item.provesLexicalMiss, let expected = item.expected {
                    let expectedIDs = [expected] + item.alternates
                    let expectedMemories = try expectedIDs.map { try #require(memories[$0]) }
                    let hybridHasExpected = hybrid.memories.contains { memory in expectedMemories.contains { $0.id == memory.id } }
                    let lexicalHasExpected = lexical.memories.contains { memory in expectedMemories.contains { $0.id == memory.id } }
                    #expect(!lexicalHasExpected)
                    if hybridHasExpected && !lexicalHasExpected {
                        lexicalMisses += 1
                    }
                }
            }

            // These counts make the intended quality gate visible in test output
            // while keeping each individual fixture diagnostic above actionable.
            #expect(lexicalMisses >= 5)
            #expect(emptyNegatives >= 3)
            await lexicalStore.close()
            await store.close()
        } catch {
            if let lexicalStore { await lexicalStore.close() }
            if let semanticStore { await semanticStore.close() }
            await workspaces.close()
            await authority.close()
            await service.close()
            try? database.close()
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
        await workspaces.close()
        await authority.close()
        await service.close()
        try database.close()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private static let fixtures: [Fixture] = [
        .init(id: "boss", content: "Everyone on my team calls me Boss."),
        .init(id: "boss-zh", content: "用户希望被称呼为「Boss」。"), // i18n-fixture: Exact Chinese nickname record from the synthetic acceptance report.
        .init(id: "diet", content: "I avoid dairy and choose fruit and oats for breakfast."),
        .init(id: "communication", content: "Start answers with the conclusion, then add brief supporting details."),
        .init(id: "schedule", content: "I reserve weekday mornings for uninterrupted deep work."),
        .init(id: "travel", content: "When I travel, I book quiet lodging near public transit."),
        .init(id: "language", content: "For technical explanations, I prefer English with code examples."),
        .init(id: "commute", content: "I usually commute by subway rather than driving."),
        .init(id: "reading", content: "I am working through a book about behavioral economics."),
        .init(id: "exercise", content: "I run three times a week before dinner."),
        .init(id: "music", content: "Instrumental music helps me concentrate while writing."),
        .init(id: "pet", content: "My dog's name is Mochi."),
        .init(id: "budget", content: "I keep travel lodging under 180 dollars per night."),
        .init(id: "meeting", content: "I avoid meetings before 10 in the morning."),
        .init(id: "weather", content: "I prefer mild weather and shade on outdoor trips."),
        .init(id: "security", content: "I use a hardware security key for important accounts."),
        .init(id: "cuisine", content: "I like spicy Sichuan food for dinner."),
        .init(id: "home", content: "I live in Vancouver."),
        .init(id: "camera", content: "I use a compact mirrorless camera."),
        .init(id: "zh-quiet-hotel", content: "我喜欢安静、靠近地铁的酒店。"), // i18n-fixture: Chinese memory content for cross-language retrieval.
    ]

    private static let queries: [QueryCase] = [
        .init("nickname-zh", "叫我啥", expected: "boss-zh", alternates: ["boss"], provesLexicalMiss: true), // i18n-fixture: Chinese nickname query.
        .init("nickname-en", "What name should I answer to?", expected: "boss", alternates: ["boss-zh"], provesLexicalMiss: true),
        .init("diet-breakfast", "What should a morning meal planner leave out?", expected: "diet"),
        .init("communication-structure", "How do I want responses organized?", expected: "communication", provesLexicalMiss: true),
        .init("schedule-deep-work", "When should I set aside time for sustained concentration?", expected: "schedule", provesLexicalMiss: true),
        .init("travel-lodging-zh", "出差时应该住什么样的地方？", expected: "zh-quiet-hotel", provesLexicalMiss: true), // i18n-fixture: Chinese query tests cross-language lodging retrieval.
        .init("commute-zh", "我平时怎样去上班？", expected: "commute", provesLexicalMiss: true), // i18n-fixture: Chinese query tests English memory cross-language retrieval.
        .init("writing-background", "What background sound helps me focus on prose?", expected: "music"),
        .init("meeting-start", "At what point in the day are meetings acceptable?", expected: "meeting"),
        .init("critical-login", "What safeguards do I use for sensitive access?", expected: "security"),
        .init("outdoor-conditions", "What climate suits me on excursions?", expected: "weather", provesLexicalMiss: true),
        .init("regional-dinner", "What cuisine do I prefer at night?", expected: "cuisine", provesLexicalMiss: true),
        .init("reading-subject", "What subject am I studying in a book?", expected: "reading"),
        .init("pet-name", "What is my pet called?", expected: "pet"),
        .init("nightly-lodging-budget", "How much can I spend on a hotel each night?", expected: "budget"),
        .init("exercise-timing", "When do I usually run?", expected: "exercise"),
        .init("home-city", "Which city is home?", expected: "home"),
        .init("hotel-close-distractor", "What kind of lodging is near public transport?", expected: "travel", expectsTop: true),
        .init("heldout-breakfast", "Which ingredients should my first meal avoid?", expected: "diet"),
        .init("heldout-transit", "What transit option do I normally take?", expected: "commute"),
        .init("heldout-communication-zh", "我更喜欢怎样的沟通方式？", expected: "communication", knownModelLimitation: true), // i18n-fixture: Retained broad Chinese communication query exposes a model limitation.
        .init("communication-focused-zh", "你回答我时，应该先给结论还是先展开细节？", expected: "communication", provesLexicalMiss: true), // i18n-fixture: Focused semantic reformulation of response-structure preference.
        .init("heldout-accommodation", "What should I prioritize when selecting accommodation?", expected: "travel"),
        .init("heldout-pet", "What name does my dog have?", expected: "pet"),
        .init("heldout-exercise", "How often am I physically active?", expected: "exercise"),
        .init("heldout-reading", "What field is the book I am reading about?", expected: "reading"),
        .init("heldout-language", "How should I show programming examples in explanations?", expected: "language"),
        .init("heldout-camera", "What kind of camera body do I use?", expected: "camera"),
        .init("heldout-budget", "What is my nightly accommodation limit?", expected: "budget"),
        .init("unrelated-quantum", "Explain quantum entanglement.", expectsEmpty: true),
        .init("unrelated-gardening", "How should I prune a rose bush?", expectsEmpty: true),
        .init("unrelated-tax", "What is the tax treatment of a bond fund?", expectsEmpty: true),
        .init("unrelated-postgres", "How do I configure a PostgreSQL index?", expectsEmpty: true),
        .init("unrelated-http", "Explain HTTP cache invalidation.", expectsEmpty: true),
        .init("unrelated-hash", "What causes a hash table collision?", expectsEmpty: true),
        .init("unrelated-compiler", "How does compiler inlining work?", expectsEmpty: true),
        .init("unrelated-tcp", "Describe TCP congestion control.", expectsEmpty: true),
        .init("unrelated-sql", "What are the tradeoffs of SQL normalization?", expectsEmpty: true),
        .init("unrelated-interest", "How do I calculate compound interest?", expectsEmpty: true),
    ]

    private static func vectorNorm(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(0) { $0 + ($1 * $1) })
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }
        return lhs.indices.reduce(0) { $0 + (lhs[$1] * rhs[$1]) }
    }
}
