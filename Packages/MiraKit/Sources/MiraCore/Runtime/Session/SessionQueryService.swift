import Foundation

/// Owns cancellable query work and its revocable payload reads. The host owns the
/// physical stores and must close this service before replacing its work group.
public actor SessionQueryService {
    private let journal: any SessionJournal
    private let payloads: any SessionPayloadReader
    private let projection: any SessionProjectionStore
    private let coordinator: SessionProjectionCoordinator
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let extensionSchemas: [String: Set<Int>]
    private let maximumPageBytes: Int
    private var jobs: [UUID: @Sendable () async -> Void] = [:]
    private var closed = false

    public init(
        journal: any SessionJournal, payloads: any SessionPayloadReader,
        projection: any SessionProjectionStore, access: AgentLibraryAccess, scope: RuntimeScope,
        maximumPageBytes: Int = 64 * 1_024 * 1_024,
        extensionSchemas: [String: Set<Int>] = [:]
    ) throws {
        guard (1...(128 * 1_024 * 1_024)).contains(maximumPageBytes) else { throw Self.invalidLimit }
        self.journal = journal
        self.payloads = payloads
        self.projection = projection
        self.access = access
        self.scope = scope
        self.maximumPageBytes = maximumPageBytes
        self.extensionSchemas = extensionSchemas
        coordinator = try SessionProjectionCoordinator(
            journal: journal, projection: projection,
            extensionSchemas: extensionSchemas)
    }

    /// Hosts synchronize affected sessions after durable wake-up hints. A full inventory
    /// is an explicit bounded refresh, not a prerequisite for every sidebar page read.
    public func synchronize(sessionID: ConversationID) async throws -> SessionJournalHead {
        try await owned { lease in
            try await lease.read { try await self.coordinator.catchUp(sessionID: sessionID) }
        }
    }

    public func synchronizeLibrary() async throws {
        try await owned { lease in
            var cursor: ConversationID?
            var seen: Set<ConversationID> = []
            while true {
                let after = cursor
                let ids = try await lease.read { try await self.journal.sessions(after: after, limit: 128) }
                guard ids.count <= 128 else { throw Self.invalidPage }
                if ids.isEmpty { break }
                for id in ids {
                    guard seen.insert(id).inserted, seen.count <= 4_096,
                        cursor.map({ $0.rawValue.uuidString < id.rawValue.uuidString }) ?? true
                    else { throw Self.invalidPage }
                    _ = try await lease.read { try await self.coordinator.catchUp(sessionID: id) }
                    cursor = id
                }
            }
        }
    }

    /// Reads only already projected metadata; callers decide when to synchronize.
    public func sessions(
        scope queryScope: SessionQueryScope = .all, includeArchived: Bool = false,
        after: SessionListCursor? = nil, limit: Int = 128
    ) async throws -> [SessionQueryItem] {
        guard (1...128).contains(limit) else { throw Self.invalidLimit }
        return try await owned { lease in
            let rows = try await lease.read {
                try await self.projection.sessions(
                    scope: queryScope, includeArchived: includeArchived, after: after, limit: limit)
            }
            guard rows.count <= limit, Set(rows.map(\.id)).count == rows.count else { throw Self.invalidPage }
            var bytes = 0
            for row in rows {
                try Self.validate(row)
                try Self.reserve(
                    row.title, invalidated: row.titleInvalidated, total: &bytes, maximum: self.maximumPageBytes)
            }
            var result: [SessionQueryItem] = []
            for row in rows {
                let title = try await self.text(row.title, invalidated: row.titleInvalidated, lease: lease)
                result.append(.init(summary: row, title: title))
            }
            return result
        }
    }

    public func messagePage(
        sessionID: ConversationID, beforeSequence: Int64? = nil,
        limit: Int = 128
    ) async throws -> SessionQueryMessagePage {
        guard (1...128).contains(limit), beforeSequence.map({ $0 > 0 }) ?? true else { throw Self.invalidLimit }
        return try await owned { lease in
            _ = try await lease.read { try await self.coordinator.catchUp(sessionID: sessionID) }
            let page = try await lease.read {
                try await self.projection.messagePage(
                    sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
            }
            try Self.validate(page, sessionID: sessionID, before: beforeSequence, limit: limit)
            var bytes = 0
            if let session = page.session {
                try Self.reserve(
                    session.title, invalidated: session.titleInvalidated, total: &bytes, maximum: self.maximumPageBytes)
            }
            for row in page.messages {
                try Self.reserve(
                    row.body, invalidated: row.bodyInvalidated, total: &bytes, maximum: self.maximumPageBytes)
                try Self.reserve(
                    row.thinking, invalidated: row.thinkingInvalidated, total: &bytes, maximum: self.maximumPageBytes)
            }
            let session: SessionQueryItem?
            if let row = page.session {
                session = .init(
                    summary: row, title: try await self.text(row.title, invalidated: row.titleInvalidated, lease: lease)
                )
            } else {
                session = nil
            }
            var messages: [SessionQueryMessage] = []
            for row in page.messages {
                let body = try await self.text(row.body, invalidated: row.bodyInvalidated, lease: lease)
                let thinking = try await self.text(row.thinking, invalidated: row.thinkingInvalidated, lease: lease)
                messages.append(.init(summary: row, body: body, thinking: thinking))
            }
            return .init(session: session, messages: messages, executions: page.executions, hasMore: page.hasMore)
        }
    }

    /// Reads one execution's authoritative journal audit at a fixed head. This is
    /// metadata plus explicitly retained payloads; it never consults the query
    /// projection for execution eligibility and never performs execution work.
    public func executionAudit(
        sessionID: ConversationID, executionID: ExecutionID,
        beforeSequence: Int64? = nil, limit: Int = 32
    ) async throws -> SessionExecutionAuditPage {
        guard (1...32).contains(limit), beforeSequence.map({ $0 > 0 }) ?? true else {
            throw Self.invalidLimit
        }
        return try await owned { lease in
            let reader = JournalSessionReader(
                journal: self.journal, payloads: self.payloads,
                extensionSchemas: self.extensionSchemas)
            try Task.checkCancellation()
            let snapshot = try await lease.read { try await reader.snapshot(sessionID: sessionID) }
            try Task.checkCancellation()
            let page = try await lease.read {
                try await SessionAuditReader.read(
                    snapshot: snapshot, sessionID: sessionID, executionID: executionID,
                    beforeSequence: beforeSequence, limit: limit,
                    maximumPageBytes: self.maximumPageBytes,
                    payloads: lease.reader(from: self.payloads))
            }
            try Task.checkCancellation()
            try await lease.check()
            try Task.checkCancellation()
            return page
        }
    }

    /// Reads bounded model and tool activity from one journal snapshot. This is
    /// display metadata only and never consults providers or execution state.
    public func executionActivities(
        sessionID: ConversationID, executionIDs: [ExecutionID]
    ) async throws -> [ExecutionID: [SessionActivityStep]] {
        guard executionIDs.count <= SessionActivityReader.maximumExecutionIDs,
              Set(executionIDs).count == executionIDs.count else { throw Self.invalidLimit }
        return try await owned { lease in
            let snapshot = try await lease.read {
                try await JournalSessionReader(
                    journal: self.journal, payloads: self.payloads,
                    extensionSchemas: self.extensionSchemas
                ).snapshot(sessionID: sessionID)
            }
            let values = try await lease.read {
                try await SessionActivityReader.read(
                    snapshot: snapshot, sessionID: sessionID, executionIDs: executionIDs,
                    maximumPageBytes: self.maximumPageBytes, journal: self.journal,
                    payloads: lease.reader(from: self.payloads))
            }
            try await lease.check()
            return values
        }
    }

    /// Loads a persisted visible draft for recovery, not for per-token UI polling.
    public func persistedDraft(sessionID: ConversationID) async throws -> SessionQueryDraft? {
        try await owned { lease in
            let snapshot = try await lease.read {
                try await JournalSessionReader(
                    journal: self.journal, payloads: self.payloads,
                    extensionSchemas: self.extensionSchemas
                ).snapshot(sessionID: sessionID)
            }
            guard let executionID = snapshot.state.activeExecutionID,
                !snapshot.state.excludedExecutionIDs.contains(executionID)
            else { return nil }
            let values = try await lease.read {
                try await SessionDraftReader(journal: self.journal, payloads: lease.reader(from: self.payloads))
                    .read(state: snapshot.state, executionID: executionID, parts: [.answer, .thinking])
            }
            let answer = values[.answer, default: Data()]
            let thinking = values[.thinking, default: Data()]
            guard answer.count <= self.maximumPageBytes, thinking.count <= self.maximumPageBytes - answer.count else {
                throw Self.pageTooLarge
            }
            return .init(
                head: snapshot.head, executionID: executionID,
                answer: try Self.decode(answer), thinking: try Self.decode(thinking))
        }
    }

    public func close() async {
        closed = true
        let drains = Array(jobs.values)
        let coordinator = coordinator
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await coordinator.close() }
            for drain in drains { group.addTask { await drain() } }
        }
    }

    private func text(
        _ reference: SessionPayloadReference?, invalidated: Bool,
        lease: AgentLibraryAccessLease
    ) async throws -> SessionTextContent {
        guard let reference else { return .absent }
        if invalidated { return .purged }
        let bytes = try await lease.read { try await self.payloads.read(reference) }
        guard bytes.count == reference.byteCount else { throw Self.invalidPage }
        return .available(try Self.decode(bytes))
    }

    private static func validate(_ session: SessionSummary) throws {
        try session.head.validate()
        try session.title.validate()
        guard session.head.cursor.sessionID == session.id, session.head.cursor.sequence > 0,
            session.title.sessionID == session.id, session.title.kind == .title, session.revision > 0
        else { throw invalidPage }
    }

    private static func validate(
        _ page: SessionProjectionMessagePage, sessionID: ConversationID,
        before: Int64?, limit: Int
    ) throws {
        guard let session = page.session else {
            guard page.messages.isEmpty, page.executions.isEmpty, !page.hasMore else { throw invalidPage }
            return
        }
        try validate(session)
        guard session.id == sessionID, page.messages.count <= limit,
            !page.hasMore || page.messages.count == limit,
            Set(page.messages.map(\.id)).count == page.messages.count,
            Set(page.executions.map(\.id)).count == page.executions.count
        else { throw invalidPage }
        var previous = before
        for row in page.messages {
            guard row.sessionID == sessionID, row.sequence > 0, row.sequence <= session.head.cursor.sequence,
                previous.map({ row.sequence < $0 }) ?? true
            else { throw invalidPage }
            previous = row.sequence
            try validate(row.body, kind: row.role == .user ? .userText : .visibleAnswer, sessionID: sessionID)
            try validate(row.thinking, kind: .visibleThinking, sessionID: sessionID)
        }
        var expected = Set(page.messages.map(\.executionID))
        if let active = session.activeExecutionID { expected.insert(active) }
        if let latest = session.latestExecutionID { expected.insert(latest) }
        guard Set(page.executions.map(\.id)) == expected,
            page.executions.allSatisfy({
                $0.sessionID == sessionID && $0.sequence > 0 && $0.sequence <= session.head.cursor.sequence
            })
        else { throw invalidPage }
        if !page.messages.isEmpty || !page.executions.isEmpty {
            guard let latestID = session.latestExecutionID,
                let latest = page.executions.first(where: { $0.id == latestID }),
                latest.sequence == page.executions.map(\.sequence).max()
            else { throw invalidPage }
        }
        if let activeID = session.activeExecutionID {
            guard activeID == session.latestExecutionID,
                let active = page.executions.first(where: { $0.id == activeID }), active.completion == nil
            else { throw invalidPage }
        }
    }

    private static func validate(
        _ reference: SessionPayloadReference?, kind: SessionPayloadKind,
        sessionID: ConversationID
    ) throws {
        guard let reference else { return }
        try reference.validate()
        guard reference.kind == kind, reference.sessionID == sessionID else { throw invalidPage }
    }

    private static func reserve(
        _ reference: SessionPayloadReference?, invalidated: Bool,
        total: inout Int, maximum: Int
    ) throws {
        guard let reference else {
            guard !invalidated else { throw invalidPage }
            return
        }
        if invalidated { return }
        guard reference.byteCount >= 0, reference.byteCount <= maximum - total else { throw pageTooLarge }
        total += reference.byteCount
    }

    private static func decode(_ bytes: Data) throws -> String {
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw MiraError(.storage, "The session payload contains invalid text encoding.")
        }
        return text
    }

    private func owned<T: Sendable>(_ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T)
        async throws -> T
    {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.busy, "The session query service is closed.") }
        guard jobs.count < 16 else { throw MiraError(.busy, "Too many session queries are in progress.") }
        let id = UUID()
        let task = Task {
            defer { self.jobs[id] = nil }
            return try await self.perform(operation)
        }
        jobs[id] = {
            task.cancel()
            _ = await task.result
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T)
        async throws -> T
    {
        let lease = try await access.acquire(in: scope)
        let resource: AgentLibraryResourceLease<Task<T, any Error>>
        do {
            resource = try await lease.start {
                let task = Task { try await operation(lease) }
                return AgentLibraryResource(
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
        do {
            try lease.bindCancellation { resource.value.cancel() }
            let value = try await withTaskCancellationHandler(
                operation: { try await resource.value.value },
                onCancel: { resource.value.cancel() })
            try await lease.check()
            await resource.release()
            await lease.release()
            return value
        } catch {
            await resource.release()
            await lease.release()
            throw error
        }
    }

    private static var invalidLimit: MiraError { .init(.invalidInput, "The session query limit is invalid.") }
    private static var invalidPage: MiraError { .init(.storage, "The session query page is inconsistent.") }
    private static var pageTooLarge: MiraError {
        .init(.outputLimit, "The session query page exceeds its content limit.")
    }
}
