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
                selection = try await resolve(for: job)
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
            let claim: MemoryExtractionClaim
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
            await process(claim, lease: lease)
        }
        return progressed
    }

    private func process(_ claim: MemoryExtractionClaim, lease: AgentLibraryAccessLease) async {
        do {
            try claim.validate()
            let adapter = try catalog.model(identity: claim.route.adapter)
            let input = try MemoryExtractionRequestBuilder.input(for: claim)
            let prepared = try await Self.timed(clock: environment.clock, seconds: 30) {
                try Task.checkCancellation()
                let value = try adapter.prepare(input, route: claim.route)
                try Task.checkCancellation()
                return value
            }
            try prepared.validate(for: claim.route)
            guard prepared.input == input else {
                throw MiraError(.configuration, "The extraction adapter changed its prepared model input.")
            }
            var source = try await freshSource(for: claim, lease: lease)
            _ = try await store.prepareMemoryExtraction(
                claim, request: prepared, source: source,
                authorization: lease.authorization, at: timestamp())
            emit(.changed)
            let modelLease = try await scheduler.acquire(executionID: claim.executionID, priority: .background)
            let output: AgentModelOutput
            do {
                try await validateSelection(claim)
                source = try await freshSource(for: claim, lease: lease)
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
            source = try await freshSource(for: claim, lease: lease)
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

    private func resolve(for job: MemoryExtractionJob) async throws -> AgentModelRouteResolution {
        try await resolver.resolve(
            purpose: AgentModelPurposeID.memoryExtraction, explicitRouteID: nil,
            sessionSelection: .inherit, workspaceID: job.workspaceID, catalog: catalog,
            requiredCapabilities: [AgentModelCapabilityID.jsonOutput])
    }

    private func validateSelection(_ claim: MemoryExtractionClaim) async throws {
        guard try await resolve(for: claim.job) == claim.selection else {
            throw MiraError(.configuration, "The dedicated memory extraction route has changed.")
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
                    guard result.finishReason == .stop else {
                        throw MiraError(.outputLimit, "Memory extraction did not finish with a complete text result.")
                    }
                    return result
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
        error is CancellationError ? .init(.cancelled, "Memory extraction was cancelled.") : MiraError.safe(error)
    }
    private func emit(_ event: MemoryExtractionWorkerEvent) {
        for observer in observers.values { observer.yield(event) }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
}

/// Builds a bounded single-call model input. Evidence identity stays in the business attempt;
/// the model sees original text and provenance dates, never authority-bearing IDs it could reuse.
public enum MemoryExtractionRequestBuilder {
    public static let revision = 1
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
        try claim.validate()
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let source = JSONValue.object([
            "content": .string(claim.source.text),
            "createdAt": .string(timestamp.string(from: claim.source.admittedAt)),
            "timeZone": .string(claim.source.timeZoneIdentifier),
        ])
        let input = AgentModelInput(
            stepID: claim.attemptID, executionID: claim.executionID,
            instructions: MemoryExtractionValidator.instructions + " Use this exact output schema: "
                + (try MemoryExtractionValidator.outputSchema.jsonString()),
            messages: [.init(role: .user,
                             blocks: [.init(id: "user", content: .text(try source.jsonString()))])], tools: [])
        try input.validate(for: claim.route)
        return input
    }
}
