import Foundation
import MiraCore
import Observation

enum MemoryScopeChoice: Hashable, Sendable {
    case global
    case workspace(WorkspaceID)

    init(scope: MemoryScope) {
        if let workspaceID = scope.workspaceID {
            self = .workspace(workspaceID)
        } else {
            self = .global
        }
    }

    var scope: MemoryScope {
        switch self {
        case .global: .global
        case .workspace(let id): .workspace(id)
        }
    }
}

private struct MemorySourceIdentity: Sendable, Equatable {
    let sessionID: ConversationID
    let messageID: MessageID
    let executionID: ExecutionID
    let sequence: Int64
    let role: SessionMessageRole
}

private struct MemorySubmission: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case userMessage(MemorySourceIdentity, excerpt: String)
        case manual(statement: String)
    }

    let draft: MemoryDraft
    let source: Source?
    let existingID: MemoryID?
    let existingRevision: Int?
    let existingWorkspaceID: WorkspaceID?
    let replacingID: MemoryID?
    let replacingRevision: Int?
    let operationID: UUID
}

private struct MemorySaveToken: Sendable, Equatable {
    let observationID: UUID
    let generation: UInt64?
}

/// Owns the editable memory draft and the identity of its durable write.
///
/// Query messages are display hints only. A user-message source is rebuilt from
/// the authoritative session state immediately before the memory application is
/// called; the application then resolves that reference through the journal.
@MainActor @Observable
final class MemoryEditorModel {
    let library: MacLibrary
    let workspaces: [Workspace]
    private let existingID: MemoryID?
    private let existingRevision: Int?
    private let existingWorkspaceID: WorkspaceID?
    private let existingAllowedConnectionIDs: Set<ConnectionID>?
    private let replacingID: MemoryID?
    private let replacingRevision: Int?
    private let replacingAllowedConnectionIDs: Set<ConnectionID>?
    private let sourceIdentity: MemorySourceIdentity?
    private(set) var operationID = UUID()

    var subject: MemorySubject
    var kind: MemoryKind
    var content: String
    var evidenceExcerpt: String
    var sensitive: Bool
    var allowsRemoteUse: Bool
    var hasValidFrom: Bool
    var hasValidUntil: Bool
    var validFrom: Date
    var validUntil: Date

    private(set) var sourceText: String?
    private(set) var sourceLoading = false
    private(set) var saving = false
    private(set) var saved = false
    private(set) var receipt: MemoryWriteReceipt?
    private(set) var error: MiraError?
    var isEditingExisting: Bool { existingID != nil }
    var isReplacing: Bool { replacingID != nil }
    var hasSourceMessage: Bool { sourceIdentity != nil }

    @ObservationIgnored private var observationID = UUID()
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var manualSourceStatement: String?
    @ObservationIgnored private var generation: UInt64?
    @ObservationIgnored private var scopeWasEdited = false
    @ObservationIgnored private var applyingScope = false
    @ObservationIgnored private var pendingSubmission: MemorySubmission?

    init(
        library: MacLibrary, workspaces: [Workspace], existing: Memory? = nil,
        replacing: Memory? = nil, sourceMessage: SessionQueryMessage? = nil
    ) {
        self.library = library
        self.workspaces = workspaces
        existingID = existing?.id
        existingRevision = existing?.revision
        existingWorkspaceID = existing?.scope.workspaceID
        existingAllowedConnectionIDs = existing?.draft?.allowedConnectionIDs
        replacingID = replacing?.id
        replacingRevision = replacing?.revision
        replacingAllowedConnectionIDs = replacing?.draft?.allowedConnectionIDs
        if let sourceMessage {
            sourceIdentity = .init(
                sessionID: sourceMessage.summary.sessionID, messageID: sourceMessage.id,
                executionID: sourceMessage.summary.executionID, sequence: sourceMessage.summary.sequence,
                role: sourceMessage.summary.role)
        } else {
            sourceIdentity = nil
        }
        let original = existing ?? replacing
        let sourceText = sourceMessage?.body.text
        scopeChoice = MemoryScopeChoice(scope: original?.scope ?? .global)
        subject = original?.draft?.subject ?? original?.subject ?? .user
        kind = original?.draft?.kind ?? .fact
        content = sourceText ?? original?.draft?.content ?? ""
        evidenceExcerpt = Self.boundedExcerpt(sourceText ?? "")
        sensitive = original?.draft?.sensitivity == .sensitive
        allowsRemoteUse = original?.draft?.allowsRemoteUse ?? true
        hasValidFrom = original?.draft?.validFrom != nil
        hasValidUntil = original?.draft?.validUntil != nil
        validFrom = original?.draft?.validFrom ?? .now
        validUntil = original?.draft?.validUntil ?? .now.addingTimeInterval(86_400)
        self.sourceText = sourceText
    }

    var scopeChoice: MemoryScopeChoice {
        didSet {
            if !applyingScope { scopeWasEdited = true }
        }
    }

    func observeLibrary() async {
        let run = UUID()
        observationID = run
        stopSourceObservation()
        generation = nil
        sourceText = nil
        sourceLoading = sourceIdentity != nil

        let statuses = await library.observe()
        for await status in statuses {
            guard !Task.isCancelled, observationID == run else { break }
            switch status.phase {
            case .ready:
                guard let binding = try? await library.binding(),
                    binding.status.phase == .ready,
                    binding.status.generation == status.generation,
                    observationID == run, !Task.isCancelled
                else { continue }
                generation = status.generation
                scheduleSourceLoad(binding.workgroup, generation: status.generation, run: run)
            case .starting, .maintaining, .closing, .closed:
                invalidateSource(run: run)
            case .failed:
                invalidateSource(run: run)
                error = status.failure
            }
        }

        guard observationID == run else { return }
        observationID = UUID()
        generation = nil
        sourceText = nil
        sourceLoading = false
        saved = false
        receipt = nil
        saving = false
        stopSourceObservation()
        let retirement = retirementTask
        await retirement?.value
    }

    /// Starts one owned write. The caller may cancel after this method returns;
    /// the task remains owned here until the memory application settles it.
    func save() async {
        if let writeTask {
            await writeTask.value
            return
        }
        guard !Task.isCancelled else { return }
        saved = false
        receipt = nil
        error = nil
        if sourceIdentity != nil && !scopeWasEdited && (generation == nil || sourceLoading) {
            error = MiraError(.busy, "The source session is still loading.")
            return
        }
        let command: MemorySubmission
        do {
            let candidate = try makeSubmission(operationID: operationID)
            if let pendingSubmission, !sameWritePayload(candidate, pendingSubmission) {
                operationID = UUID()
                manualSourceStatement = nil
                command = try makeSubmission(operationID: operationID)
            } else if let pendingSubmission {
                command = pendingSubmission
            } else {
                command = candidate
            }
        } catch {
            self.error = MiraError.safe(error)
            return
        }
        pendingSubmission = command
        let token = MemorySaveToken(observationID: observationID, generation: generation)
        saving = true
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            await self?.performSave(command, token: token)
        }
        writeTask = task
        await task.value
    }

    /// Retries the same logical write with the original operation identity.
    func retrySaving() async {
        await save()
    }

    func close() async {
        observationID = UUID()
        generation = nil
        sourceText = nil
        sourceLoading = false
        saving = false
        saved = false
        receipt = nil
        error = nil
        stopSourceObservation()
        let retirement = retirementTask
        await retirement?.value
        if let writeTask {
            await writeTask.value
        }
    }

    private func performSave(_ command: MemorySubmission, token: MemorySaveToken) async {
        defer {
            if isCurrent(token) { saving = false }
            if writeTask != nil { writeTask = nil }
        }

        var boundGeneration: UInt64?
        do {
            let binding = try await library.binding()
            guard binding.status.phase == .ready else {
                throw MiraError(.busy, "Memory writes are unavailable while the library is changing.")
            }
            boundGeneration = binding.status.generation
            guard isCurrent(token, boundGeneration: boundGeneration) else { return }
            let group = binding.workgroup
            if let existingID = command.existingID,
                let existingRevision = command.existingRevision
            {
                _ = try await group.memories.reviseMemory(
                    existingID, workspaceID: command.existingWorkspaceID, draft: command.draft,
                    expectedRevision: existingRevision, operationID: command.operationID)
            } else {
                guard let source = command.source else {
                    throw MiraError(.invalidInput, "A memory source is required.")
                }
                let input: MemorySourceInput
                switch source {
                case .userMessage(let identity, let excerpt):
                    guard identity.role == .user else {
                        throw MiraError(.invalidInput, "Only a committed user message can be used as memory evidence.")
                    }
                    guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        excerpt.utf8.count <= 8_192
                    else {
                        throw MiraError(
                            .invalidInput,
                            "Memory evidence must be an exact excerpt of at most 8 KiB from the original message.")
                    }
                    let state = try await group.application.sessionSnapshot(id: identity.sessionID)
                    let reference = try authoritativeReference(for: identity, in: state)
                    input = .userMessage(reference: reference, excerpt: excerpt)
                case .manual(let statement):
                    input = .manualEntry(id: command.operationID, statement: statement)
                }
                let result = try await group.memories.createMemory(
                    draft: command.draft, source: input, operationID: command.operationID,
                    replacing: command.replacingID, expectedRevision: command.replacingRevision)
                guard await canPublish(token, boundGeneration: boundGeneration) else { return }
                receipt = result
            }
            guard await canPublish(token, boundGeneration: boundGeneration) else { return }
            saved = true
        } catch {
            guard isCurrent(token) else { return }
            if let boundGeneration,
                !(await canPublish(token, boundGeneration: boundGeneration))
            {
                return
            }
            self.error = MiraError.safe(error)
        }
    }

    private func makeSubmission(operationID: UUID) throws -> MemorySubmission {
        let draft = MemoryDraft(
            content: content, scope: scopeChoice.scope, subject: subject, kind: kind,
            sensitivity: sensitive ? .sensitive : .standard,
            allowsRemoteUse: allowsRemoteUse,
            allowedConnectionIDs: existingAllowedConnectionIDs ?? replacingAllowedConnectionIDs,
            validFrom: hasValidFrom ? validFrom : nil,
            validUntil: hasValidUntil ? validUntil : nil)
        try draft.validate()
        let source: MemorySubmission.Source?
        if let sourceIdentity {
            source = .userMessage(sourceIdentity, excerpt: evidenceExcerpt)
        } else {
            let statement = manualSourceStatement ?? content
            manualSourceStatement = statement
            source = .manual(statement: statement)
        }
        return MemorySubmission(
            draft: draft, source: existingID == nil ? source : nil,
            existingID: existingID, existingRevision: existingRevision,
            existingWorkspaceID: existingWorkspaceID, replacingID: replacingID,
            replacingRevision: replacingRevision, operationID: operationID)
    }

    private func sameWritePayload(_ lhs: MemorySubmission, _ rhs: MemorySubmission) -> Bool {
        lhs.draft == rhs.draft && lhs.source == rhs.source
            && lhs.existingID == rhs.existingID && lhs.existingRevision == rhs.existingRevision
            && lhs.existingWorkspaceID == rhs.existingWorkspaceID
            && lhs.replacingID == rhs.replacingID && lhs.replacingRevision == rhs.replacingRevision
    }

    private func authoritativeReference(
        for identity: MemorySourceIdentity, in state: SessionState
    ) throws -> SessionEvidenceReference {
        guard let execution = state.executions[identity.executionID],
            execution.admission.userMessageID == identity.messageID,
            execution.admission.retryOfExecutionID == nil,
            let body = execution.admission.userBody,
            body.batchID == execution.admissionBatchID,
            body.sessionID == identity.sessionID,
            body.kind == .userText
        else {
            throw MiraError(.unauthorized, "The selected user message is no longer authoritative evidence.")
        }
        let reference = SessionEvidenceReference(
            sessionID: identity.sessionID,
            originalExecutionID: identity.executionID,
            userMessageID: identity.messageID,
            admissionEventID: execution.admissionEventID,
            admissionSequence: execution.admissionSequence,
            body: body)
        try reference.validate()
        return reference
    }

    private func isCurrent(_ token: MemorySaveToken, boundGeneration: UInt64? = nil) -> Bool {
        guard observationID == token.observationID else { return false }
        if let tokenGeneration = token.generation {
            return generation == tokenGeneration && boundGeneration.map { $0 == tokenGeneration } ?? true
        }
        if let boundGeneration {
            return generation == nil || generation == boundGeneration
        }
        return true
    }

    private func canPublish(_ token: MemorySaveToken, boundGeneration: UInt64?) async -> Bool {
        guard isCurrent(token, boundGeneration: boundGeneration),
            let boundGeneration
        else { return false }
        let status = await library.status()
        return isCurrent(token, boundGeneration: boundGeneration)
            && status.phase == .ready && status.generation == boundGeneration
    }

    private func scheduleSourceLoad(
        _ group: MacLibraryWorkloads, generation: UInt64, run: UUID
    ) {
        guard let sourceIdentity else {
            sourceText = nil
            sourceLoading = false
            return
        }
        stopSourceObservation()
        sourceLoading = true
        let task = Task { @MainActor [weak self] in
            do {
                let page = try await group.queries.messagePage(
                    sessionID: sourceIdentity.sessionID,
                    beforeSequence: sourceIdentity.sequence + 1,
                    limit: 128)
                guard !Task.isCancelled, let self,
                    self.observationID == run, self.generation == generation
                else { return }
                guard let message = page.messages.first(where: { $0.id == sourceIdentity.messageID }),
                    message.summary.role == .user
                else {
                    self.sourceText = nil
                    self.sourceLoading = false
                    return
                }
                if !self.scopeWasEdited, let workspaceID = page.session?.summary.workspaceID {
                    self.applyingScope = true
                    self.scopeChoice = .workspace(workspaceID)
                    self.applyingScope = false
                }
                self.sourceText = message.body.text
                self.sourceLoading = false
            } catch {
                guard !Task.isCancelled, let self, self.observationID == run,
                    self.generation == generation
                else { return }
                self.sourceText = nil
                self.sourceLoading = false
            }
        }
        sourceTask = task
    }

    private func invalidateSource(run: UUID) {
        guard observationID == run else { return }
        generation = nil
        sourceText = nil
        sourceLoading = false
        saved = false
        receipt = nil
        saving = false
        stopSourceObservation()
    }

    private func stopSourceObservation() {
        guard let sourceTask else { return }
        self.sourceTask = nil
        sourceTask.cancel()
        let previous = retirementTask
        retirementTask = Task {
            await previous?.value
            await sourceTask.value
        }
    }

    private static func boundedExcerpt(_ text: String) -> String {
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= 8_192 else { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}
