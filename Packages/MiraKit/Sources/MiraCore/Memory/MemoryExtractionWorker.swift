import Foundation

public enum MemoryExtractionWorkerEvent: Sendable, Equatable {
    case changed
    case failure(MiraError)
}

/// A module-owned business worker. It shares the model catalog, stream reducer,
/// scheduler and library lifetime with foreground work; it owns no session replica.
public actor MemoryExtractionWorker {
    private let store: any MemoryExtractionStore
    private let reader: JournalSessionReader
    private let resolver: AgentModelRouteResolver
    private let catalog: AgentRuntimeCatalog
    private let scheduler: RuntimeScheduler
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let environment: RuntimeEnvironment
    private var observers: [UUID: AsyncStream<MemoryExtractionWorkerEvent>.Continuation] = [:]
    private var drainTask: Task<Void, Never>?
    private var currentTask: Task<Bool, any Error>?
    private var wakeRequested = false
    private var closed = false
    private var lastScheduledSession: ConversationID?

    /// The composition root retains the catalog until this worker has closed.
    /// Recovery runs before opening this worker, after previous producers have drained.
    public init(
        store: any MemoryExtractionStore, reader: JournalSessionReader,
        settings: any AgentModelSettingsStore, catalog: AgentRuntimeCatalog,
        scheduler: RuntimeScheduler, access: AgentLibraryAccess, scope: RuntimeScope,
        environment: RuntimeEnvironment = .init()
    ) {
        self.store = store
        self.reader = reader
        resolver = .init(settings: settings)
        self.catalog = catalog
        self.scheduler = scheduler
        self.access = access
        self.scope = scope
        self.environment = environment
    }

    public func events() -> AsyncStream<MemoryExtractionWorkerEvent> {
        let pair = AsyncStream<MemoryExtractionWorkerEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        guard !closed else {
            pair.continuation.finish()
            return pair.stream
        }
        let id = UUID()
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }

    /// Wakeups coalesce. Each pass selects at most 32 jobs, rotating sessions, and yields before continuing a backlog.
    public func wake() {
        guard !closed else { return }
        wakeRequested = true
        guard drainTask == nil else { return }
        drainTask = Task { await self.drain() }
    }

    public func cancelCurrent() { currentTask?.cancel() }

    /// Every caller waits for the same accepted work, including non-cooperative prepare/transport cleanup.
    public func close() async {
        closed = true
        wakeRequested = false
        currentTask?.cancel()
        drainTask?.cancel()
        if let drainTask { await drainTask.value }
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }

    private func drain() async {
        defer { drainTask = nil }
        while !closed && !Task.isCancelled {
            wakeRequested = false
            do {
                let progressed = try await pass()
                if !progressed && !wakeRequested { return }
                await Task.yield()
            } catch is CancellationError { return } catch {
                emit(.failure(Self.safe(error)))
                return
            }
        }
    }

    private func pass() async throws -> Bool {
        let lease = try await access.acquire(in: scope)
        let resource: AgentLibraryResourceLease<Task<Bool, any Error>>
        do {
            resource = try await lease.start {
                let task = Task { try await self.processBatch(lease: lease) }
                return .init(
                    value: task,
                    cleanup: {
                        task.cancel()
                        _ = await task.result
                    })
            }
        } catch {
            await lease.release()
            throw error
        }
        currentTask = resource.value
        defer { currentTask = nil }
        do {
            try lease.bindCancellation { resource.value.cancel() }
            let result = try await withTaskCancellationHandler(
                operation: { try await resource.value.value },
                onCancel: { resource.value.cancel() })
            await resource.release()
            await lease.release()
            return result
        } catch {
            await resource.release()
            await lease.release()
            throw error
        }
    }

    private func processBatch(lease: AgentLibraryAccessLease) async throws -> Bool {
        var progressed = false
        for _ in 0..<32 {
            try Task.checkCancellation()
            try await lease.check()
            try await store.flushDirtyMemoryExtraction(at: timestamp(), authorization: lease.authorization)
            let cursor = lastScheduledSession
            guard let job = try await lease.read({ try await self.store.nextQueuedMemoryExtraction(after: cursor) })
            else {
                return progressed
            }
            try job.validate()
            guard job.state == .queued else {
                throw MiraError(.storage, "The memory extraction queue returned an ineligible job.")
            }
            lastScheduledSession = job.origin.source.sessionID
            let source: SessionUserEvidence
            let selection: AgentModelRouteResolution
            do {
                source = try await lease.read { try await self.reader.userEvidence(job.origin.source) }
                try MemoryExtractionRequestBuilder.validate(source: source)
                selection = .init(route: try await reader.memoryExtractionContext(for: job).route, binding: nil)
                try await resolver.validateCurrent(selection.route, catalog: catalog)
            } catch {
                try Task.checkCancellation()
                try await lease.check()
                let safe = Self.safe(error)
                // Storage outages are retried by a later wake; they do not change domain eligibility.
                guard
                    [.notFound, .unauthorized, .configuration, .unsupported, .conflict, .invalidInput].contains(
                        safe.code)
                else { throw safe }
                try await store.pauseMemoryExtraction(
                    job.id, expectedAttemptCount: job.attemptCount, error: safe,
                    authorization: lease.authorization, at: timestamp())
                progressed = true
                emit(.changed)
                continue
            }
            try await lease.check()
            var claim: MemoryExtractionClaim
            do {
                guard
                    let next = try await store.claimMemoryExtraction(
                        job.id, expectedAttemptCount: job.attemptCount,
                        source: source, selection: selection, authorization: lease.authorization, at: timestamp())
                else { return progressed }
                claim = next
            } catch {
                try Task.checkCancellation()
                try await lease.check()
                let safe = Self.safe(error)
                guard
                    [.notFound, .unauthorized, .configuration, .unsupported, .conflict, .invalidInput, .outputLimit]
                        .contains(safe.code)
                else { throw safe }
                try await store.pauseMemoryExtraction(
                    job.id, expectedAttemptCount: job.attemptCount, error: safe,
                    authorization: lease.authorization, at: timestamp())
                progressed = true
                emit(.changed)
                continue
            }
            progressed = true
            emit(.changed)
            do {
                claim.batchSources = try await freshSources(for: claim, lease: lease)
                claim.assistantReplies = try await conversationReplies(for: claim, lease: lease)
                let prefix = try await reader.memoryExtractionContext(for: claim.job)
                claim.prefix = prefix.bounded(for: claim)
            } catch {
                await settle(claim, error: Self.safe(error), lease: lease)
                continue
            }
            await process(claim, lease: lease)
        }
        return progressed
    }

    private func process(_ initialClaim: MemoryExtractionClaim, lease: AgentLibraryAccessLease) async {
        var claim = initialClaim
        do {
            try claim.validate()
            let adapter = try catalog.model(identity: claim.route.adapter)
            claim.outputTokenLimit = try adapter.outputTokenLimit(
                for: MemoryExtractionRequestBuilder.outputTokenTarget, route: claim.route)
            let preparation = try await prepare(claim, adapter: adapter, lease: lease)
            claim = preparation.claim
            let prepared = preparation.request
            var source = preparation.source
            emit(.changed)
            let modelLease = try await scheduler.acquire(executionID: claim.executionID, priority: .background)
            let output: AgentModelOutput
            do {
                try await validateSelection(claim)
                claim.batchSources = try await freshSources(for: claim, lease: lease)
                source = try await freshSource(for: claim, lease: lease)
                try await validateConversationReplies(claim, lease: lease)
                try await store.markMemoryExtractionDispatched(
                    claim, source: source,
                    authorization: lease.authorization, at: timestamp())
                try Task.checkCancellation()
                try await lease.check()
                output = try await collect(prepared, claim: claim, adapter: adapter, lease: lease)
                await modelLease.release()
            } catch {
                await modelLease.release()
                throw error
            }
            claim.batchSources = try await freshSources(for: claim, lease: lease)
            source = try await freshSource(for: claim, lease: lease)
            try await validateConversationReplies(claim, lease: lease)
            try await validateSelection(claim)
            _ = try await store.completeMemoryExtraction(
                claim, source: source, output: output,
                authorization: lease.authorization, at: timestamp())
            emit(.changed)
        } catch {
            let failure = Self.safe(error)
            let at = environment.now()
            // Settlement outlives cancellation of observation; maintenance can reject the old epoch.
            // In that case the maintenance/recovery owner settles the durable attempt, never this late worker.
            let settlement = Task {
                try await self.store.failMemoryExtraction(
                    claim, error: failure,
                    authorization: lease.authorization, at: at)
            }
            do {
                try await settlement.value
                emit(.changed)
                emit(.failure(failure))
            } catch { emit(.failure(Self.safe(error))) }
        }
    }

    private func prepare(_ initial: MemoryExtractionClaim, adapter: any AgentModelAdapter,
                         lease: AgentLibraryAccessLease) async throws
        -> (claim: MemoryExtractionClaim, request: AgentPreparedModelRequest, source: SessionUserEvidence) {
        var claim = initial
        while true {
            do {
                let input = try MemoryExtractionRequestBuilder.input(for: claim)
                let route = claim.route
                let prepared = try await Self.timed(clock: environment.clock, seconds: 30) {
                    try Task.checkCancellation()
                    let value = try adapter.prepare(input, route: route)
                    try Task.checkCancellation()
                    return value
                }
                try prepared.validate(for: route)
                guard prepared.input == input else {
                    throw MiraError(.configuration, "The extraction adapter changed its prepared model input.")
                }
                let source = try await freshSource(for: claim, lease: lease)
                try await validateConversationReplies(claim, lease: lease)
                try await validateSelection(claim)
                _ = try await store.prepareMemoryExtraction(claim, request: prepared, source: source,
                    authorization: lease.authorization, at: timestamp())
                return (claim, prepared, source)
            } catch let error as MiraError where [.contextLimit, .outputLimit].contains(error.code) {
                // Refitting is pure preparation, before any dispatch. Keep the same
                // model/system/tools and drop the optional copied history once.
                guard let prefix = claim.prefix, !prefix.input.messages.isEmpty else { throw error }
                claim.prefix = prefix.withoutMessages()
            }
        }
    }

    private func validateSelection(_ claim: MemoryExtractionClaim) async throws {
        try await resolver.validateCurrent(claim.route, catalog: catalog)
        let prefix = try await reader.memoryExtractionContext(for: claim.job)
        var expected = prefix.bounded(for: claim)
        if claim.prefix?.input.messages.isEmpty == true { expected = expected.withoutMessages() }
        guard prefix.route == claim.route, expected == claim.prefix else {
            throw MiraError(.configuration, "The conversation model or extraction prefix is no longer available.")
        }
    }

    private func freshSource(for claim: MemoryExtractionClaim, lease: AgentLibraryAccessLease) async throws
        -> SessionUserEvidence
    {
        let source = try await lease.read { try await self.reader.userEvidence(claim.job.origin.source) }
        try MemoryExtractionRequestBuilder.validate(source: source)
        guard source.reference == claim.source.reference, source.workspaceID == claim.source.workspaceID,
            source.text == claim.source.text, source.admittedAt == claim.source.admittedAt,
            source.timeZoneIdentifier == claim.source.timeZoneIdentifier,
            source.sessionAuthorizationEpoch == claim.source.sessionAuthorizationEpoch
        else {
            throw MiraError(.unauthorized, "The memory extraction source authorization has changed.")
        }
        try await lease.check()
        return source
    }

    private func freshSources(for claim: MemoryExtractionClaim, lease: AgentLibraryAccessLease) async throws -> [SessionUserEvidence] {
        let references = claim.job.turns.isEmpty ? [claim.source.reference] : claim.job.turns.map(\.source)
        var result: [SessionUserEvidence] = []
        for reference in references {
            let evidence = try await lease.read { try await self.reader.userEvidence(reference) }
            try MemoryExtractionRequestBuilder.validate(source: evidence)
            guard evidence.workspaceID == claim.job.workspaceID else { throw MiraError(.unauthorized, "The extraction batch crosses workspace scope.") }
            guard try await isFresh(evidence, claim: claim, lease: lease) else {
                throw MiraError(.unauthorized, "A batched memory source authorization has changed.")
            }
            result.append(evidence)
        }
        return result
    }

    private func conversationReplies(for claim: MemoryExtractionClaim, lease: AgentLibraryAccessLease) async throws -> [String?] {
        var result: [String?] = []
        for turn in claim.job.turns {
            result.append(try await lease.read { try await self.reader.memoryExtractionReply(turn) })
        }
        return result
    }

    private func validateConversationReplies(_ claim: MemoryExtractionClaim, lease: AgentLibraryAccessLease) async throws {
        guard try await conversationReplies(for: claim, lease: lease) == claim.assistantReplies else {
            throw MiraError(.unauthorized, "The extraction conversation context changed.")
        }
        _ = try await freshSources(for: claim, lease: lease)
    }

    private func isFresh(_ evidence: SessionUserEvidence, claim: MemoryExtractionClaim, lease: AgentLibraryAccessLease) async throws -> Bool {
        if evidence.reference == claim.source.reference { return true }
        try await lease.check()
        return evidence.sessionAuthorizationEpoch == claim.source.sessionAuthorizationEpoch
    }

    private func settle(_ claim: MemoryExtractionClaim, error: MiraError, lease: AgentLibraryAccessLease) async {
        do { try await store.failMemoryExtraction(claim, error: error, authorization: lease.authorization, at: environment.now()) }
        catch { emit(.failure(Self.safe(error))) }
    }

    private func collect(
        _ request: AgentPreparedModelRequest, claim: MemoryExtractionClaim,
        adapter: any AgentModelAdapter, lease: AgentLibraryAccessLease
    ) async throws -> AgentModelOutput {
        let resource = try await lease.start {
            let operation = adapter.stream(request, route: claim.route)
            return AgentLibraryResource(value: operation, cleanup: { await operation.close() })
        }
        do {
            let output = try await withTaskCancellationHandler {
                try await Self.timed(clock: environment.clock, seconds: 90) {
                    var accumulator = try AgentModelAccumulator(route: claim.route, maximumTextBytes: 32_768)
                    for try await event in resource.value.events {
                        try Task.checkCancellation()
                        if case .blockStarted(let block) = event,
                           case .toolCall = block.content {
                            throw MiraError(.providerRejected, "Memory extraction does not permit tool calls.")
                        }
                        try accumulator.consume(event)
                    }
                    try Task.checkCancellation()
                    let result = try accumulator.finish()
                    switch result.finishReason {
                    case .stop:
                        return result
                    case .outputLimit:
                        throw MiraError(.outputLimit, "Memory extraction did not finish with a complete text result.")
                    case .toolCalls:
                        throw MiraError(.providerRejected, "Memory extraction does not permit tool calls.")
                    }
                }
            } onCancel: {
                Task { await resource.value.close() }
            }
            await resource.release()
            return output
        } catch {
            await resource.release()
            throw error
        }
    }

    private static func timed<T: Sendable>(
        clock: any RuntimeClock, seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: .seconds(seconds))
                throw MiraError(.timeout, "Memory extraction exceeded its operation deadline.")
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return value
        }
    }

    private func timestamp() throws -> Date {
        let date = environment.now()
        guard date.timeIntervalSince1970.isFinite else {
            throw MiraError(.configuration, "The extraction clock returned an invalid date.")
        }
        return date
    }
    private static func safe(_ error: any Error) -> MiraError {
        if error is CancellationError {
            return .init(.cancelled, "Memory extraction was cancelled.")
        }
        if let failure = error as? AgentModelFailure {
            if failure.error.code == .cancelled {
                return .init(.cancelled, "Memory extraction was cancelled.")
            }
            // Adapter failures carry a safe classification as well as a message.
            // Keep the classification for diagnosis, but do not persist adapter
            // supplied text in the business job's durable error field.
            return .init(failure.error.code, "The memory extraction model request failed.")
        }
        return MiraError.safe(error)
    }
    private func emit(_ event: MemoryExtractionWorkerEvent) {
        for observer in observers.values { observer.yield(event) }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
}

/// Reusable foreground prefix. Bodies are admitted only when their entire lineage
/// is already owned by the extraction batch or its revision-checked prior memories.
public struct MemoryExtractionPrefix: Sendable, Equatable {
    public let route: AgentModelRoute
    public let input: AgentModelInput
    public let sources: [AgentSourceReference]

    public init(route: AgentModelRoute, input: AgentModelInput, sources: [AgentSourceReference]) {
        self.route = route; self.input = input; self.sources = sources
    }

    public func bounded(for claim: MemoryExtractionClaim) -> Self {
        let executions = Set(claim.job.turns.map(\.completedExecutionID) + [claim.job.origin.completedExecutionID])
        let covered = sources.allSatisfy { source in
            switch source {
            case .sessionExecution(let sessionID, let executionID):
                return sessionID == claim.job.origin.source.sessionID && executions.contains(executionID)
            case .domain(let namespace, let id, let revision):
                return namespace == "memories" && claim.existingMemories.contains { $0.id.rawValue == id && $0.revision == revision }
            }
        }
        // Avoid paying for unbounded history to chase a best-effort cache hit. The
        // stable system instructions and tool schema remain reusable when history
        // exceeds this bound or would introduce untracked privacy dependencies.
        let bytes = (try? SessionCodec.encode(input.messages).count) ?? Int.max
        let messages = covered && bytes <= 16_384 && input.messages.count < 256 ? input.messages : []
        return messages.isEmpty ? withoutMessages() : self
    }

    public func withoutMessages() -> Self {
        .init(route: route, input: .init(stepID: input.stepID, executionID: input.executionID,
            instructions: input.instructions, messages: [], tools: input.tools), sources: [])
    }
}

/// Builds a bounded single-call model input. Evidence identity stays in the business attempt;
/// the model sees original text and provenance dates, never authority-bearing IDs it could reuse.
public enum MemoryExtractionRequestBuilder {
    public static let revision = 5
    public static let outputTokenTarget = 8_192
    public static func validate(source: SessionUserEvidence) throws {
        try source.reference.validate()
        try source.observedHead.validate()
        guard !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.text.utf8.count <= 16_384,
            source.admittedAt.timeIntervalSince1970.isFinite, TimeZone(identifier: source.timeZoneIdentifier) != nil,
            source.observedHead.cursor.sessionID == source.reference.sessionID,
            source.observedHead.cursor.sequence >= source.reference.admissionSequence
        else {
            throw MiraError(.invalidInput, "The memory extraction evidence is invalid or exceeds its limit.")
        }
    }
    public static func input(for claim: MemoryExtractionClaim) throws -> AgentModelInput {
        try input(for: claim, sources: claim.batchSources)
    }

    /// Builds the production multi-turn request. Input indexes are internal
    /// lineage only; the host maps them back to journal references before any
    /// commit and they are never shown as user citations.
    public static func input(for claim: MemoryExtractionClaim, sources: [SessionUserEvidence]) throws -> AgentModelInput {
        try claim.validate()
        guard !sources.isEmpty, sources.count <= MemoryExtractionBatching.maximumTurns else {
            throw MiraError(.invalidInput, "The extraction batch is empty or exceeds its turn bound.")
        }
        var total = 0
        var entries: [JSONValue] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (index, source) in sources.enumerated() {
            try MemoryExtractionRequestBuilder.validate(source: source)
            total += max(1, source.text.utf8.count / 4)
            guard total <= MemoryExtractionBatching.maximumInputTokens else {
                throw MiraError(.outputLimit, "The extraction context exceeds its bounded input budget.")
            }
            entries.append(.object([
                "inputIndex": .number(Double(index)),
                "speaker": .string("user"),
                "content": .string(source.text),
                "createdAt": .string(formatter.string(from: source.admittedAt)),
                "timeZone": .string(source.timeZoneIdentifier)
            ]))
            if claim.assistantReplies.indices.contains(index), let reply = claim.assistantReplies[index] {
                entries.append(.object(["speaker": .string("assistant"), "content": .string(reply),
                                        "contextOnly": .bool(true)]))
            }
        }
        let existing = claim.existingMemories.enumerated().compactMap { index, memory -> JSONValue? in
            guard let draft = memory.draft else { return nil }
            return .object(["index": .number(Double(index)), "content": .string(draft.content),
                            "subject": .string(memory.subject.rawValue), "kind": .string(draft.kind.rawValue),
                            "validFrom": draft.validFrom.map { .string(formatter.string(from: $0)) } ?? .null,
                            "validUntil": draft.validUntil.map { .string(formatter.string(from: $0)) } ?? .null])
        }
        let payload = JSONValue.object(["turns": .array(entries), "existingMemories": .array(existing)])
        let task = MemoryExtractionValidator.instructions + " This is an internal background memory extraction task. Return JSON only; do not answer the conversation or call tools. Extract facts only from the explicitly listed target turns below. Earlier conversation and recalled memories are context, not new evidence. Every item must include inputIndex identifying the supporting target user turn. Do not emit visible citations. Use this exact output schema: " + (try MemoryExtractionValidator.outputSchema.jsonString())
        let prefix = claim.prefix
        let messages = prefix?.input.messages ?? []
        let input = AgentModelInput(
            stepID: claim.attemptID, executionID: claim.executionID,
            instructions: prefix?.input.instructions ?? MemoryExtractionValidator.instructions,
            messages: messages + [.init(role: .user, blocks: [.init(id: "memory-extraction", content: .text(task + "\nTarget input:\n" + (try payload.jsonString())))])],
            tools: prefix?.input.tools ?? [], allowsToolCalls: false,
            prefixMessageCount: messages.isEmpty ? nil : messages.count,
            outputTokenLimit: claim.outputTokenLimit ?? min(outputTokenTarget, claim.route.maximumOutputTokens))
        try input.validate(for: claim.route)
        return input
    }
}
