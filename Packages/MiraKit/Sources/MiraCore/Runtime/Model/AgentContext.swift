import Foundation

/// Business sources are resolved by their owning domain; execution sources by the authoritative session journal.
/// Neither variant refers to a row in a disposable conversation projection.
public enum AgentSourceReference: Codable, Sendable, Equatable, Hashable {
    case domain(namespace: String, id: UUID, revision: Int)
    case sessionExecution(sessionID: ConversationID, executionID: ExecutionID)

    public func validate() throws {
        if case .domain(let namespace, _, let revision) = self {
            guard SessionState.validIdentifier(namespace, maximumBytes: 128), revision > 0 else {
                throw MiraError(.invalidInput, "The context source reference is invalid.")
            }
        }
    }

    static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.domain(leftNamespace, leftID, leftRevision), .domain(rightNamespace, rightID, rightRevision)):
            if leftNamespace != rightNamespace { return leftNamespace < rightNamespace }
            if leftID != rightID { return leftID.uuidString < rightID.uuidString }
            return leftRevision < rightRevision
        case let (.sessionExecution(leftSession, leftExecution), .sessionExecution(rightSession, rightExecution)):
            if leftSession != rightSession { return leftSession.rawValue.uuidString < rightSession.rawValue.uuidString }
            return leftExecution.rawValue.uuidString < rightExecution.rawValue.uuidString
        case (.domain, .sessionExecution): return true
        case (.sessionExecution, .domain): return false
        }
    }
}

/// A source is authorized for an explicit destination, never for an unspecified connection.
public enum AgentContextDestination: Codable, Sendable, Equatable {
    case local
    case model(AgentModelRoute)

    public var modelRoute: AgentModelRoute? {
        if case .model(let route) = self { route } else { nil }
    }
}

public struct AgentContextRequest: Codable, Sendable, Equatable {
    public let sessionID: ConversationID
    public let executionID: ExecutionID
    public let workspaceID: WorkspaceID?
    public let userText: String
    public let authorizationEpoch: UInt64
    public let destination: AgentContextDestination
    public init(sessionID: ConversationID, executionID: ExecutionID, workspaceID: WorkspaceID?,
                userText: String, authorizationEpoch: UInt64, destination: AgentContextDestination) {
        self.sessionID = sessionID; self.executionID = executionID; self.workspaceID = workspaceID
        self.userText = userText; self.authorizationEpoch = authorizationEpoch
        self.destination = destination
    }
}

/// Contributors provide data, not trusted instructions. Each assembly collects a contributor once;
/// budget adjustments reuse its values while sources are revalidated at the effect boundary.
public struct AgentContextItem: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let sources: [AgentSourceReference]
    public let priority: Int
    public init(id: String, text: String, sources: [AgentSourceReference], priority: Int = 0) {
        self.id = id; self.text = text; self.sources = sources; self.priority = priority
    }
}

public protocol AgentContextContributor: Sendable {
    var id: String { get }
    var isRequired: Bool { get }
    func contribute(to request: AgentContextRequest) async throws -> [AgentContextItem]
}

public protocol AgentSourceAuthorizer: Sendable {
    /// Must consult each source's owning authority and current policy, never a possibly stale query projection.
    /// Definite revocation or source removal is `unauthorized`; an unavailable authority is a storage failure.
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws
}

public struct AgentContextOmission: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable { case unavailable, invalid, unauthorized, budget }
    public let contributorID: String
    public let itemID: String?
    public let reason: Reason
}

public struct AgentContextEvidence: Codable, Sendable, Equatable {
    public let contributorID: String
    public let itemID: String
    public let sources: [AgentSourceReference]
}

/// Eligibility-filtered history and its transitive sources travel together into request preparation.
public struct AgentContextHistory: Codable, Sendable, Equatable {
    public let messages: [AgentModelMessage]
    public let sources: [AgentSourceReference]
    public init(messages: [AgentModelMessage], sources: [AgentSourceReference]) {
        self.messages = messages; self.sources = sources
    }
}

/// The ordinary contributor result captured for the first request in a turn.
/// Tool continuation may add committed tool provenance, but it must not recollect
/// this same-turn context and observe a different contributor snapshot.
public struct AgentFrozenContext: Sendable, Equatable {
    public let message: AgentModelMessage?
    public let evidence: [AgentContextEvidence]
    public let omissions: [AgentContextOmission]
    public let sources: [AgentSourceReference]
    public init(message: AgentModelMessage?, evidence: [AgentContextEvidence],
                omissions: [AgentContextOmission], sources: [AgentSourceReference]) {
        self.message = message; self.evidence = evidence; self.omissions = omissions; self.sources = sources
    }
}

/// Process-local preparation result. Persist only `AgentSessionRequest` evidence.
public struct AgentContextBuild: Sendable, Equatable {
    public let request: AgentContextRequest
    public let prepared: AgentPreparedModelRequest
    public let inheritedSources: [AgentSourceReference]
    public let evidence: [AgentContextEvidence]
    public let omissions: [AgentContextOmission]
    public var sources: [AgentSourceReference] {
        Self.orderedSources(inheritedSources + evidence.flatMap(\.sources))
    }
    static func orderedSources(_ values: [AgentSourceReference]) -> [AgentSourceReference] {
        Set(values).sorted(by: AgentSourceReference.ordered)
    }
}

public struct AgentContextAssembler: Sendable {
    private struct Entry: Codable, Sendable {
        let contributorID: String
        let item: AgentContextItem
        let required: Bool
    }
    private struct DataRecord: Codable {
        let contributor: String
        let id: String
        let text: String
        let sources: [AgentSourceReference]
    }

    public init() {}

    public func build(request: AgentContextRequest, stepID: UUID, instructions: String,
                      history: AgentSessionHistory, currentTrace: AgentContextHistory, tools: [ToolDefinition],
                      route: AgentModelRoute, adapter: any AgentModelAdapter,
                      contributors: [any AgentContextContributor], authorizer: any AgentSourceAuthorizer,
                      frozenContext: AgentFrozenContext? = nil) async throws -> AgentContextBuild {
        try Task.checkCancellation()
        try route.validate()
        guard history.exchanges.count <= 254, contributors.count <= 128 else {
            throw MiraError(.configuration, "The model context composition is invalid.")
        }
        var historicalMessageCount = 0
        for exchange in history.exchanges {
            historicalMessageCount += exchange.messages.count
            guard historicalMessageCount <= 254, exchange.sources.count <= 8_192 else {
                throw MiraError(.configuration, "The model context composition is invalid.")
            }
        }
        var history = history
        var historyContext = history.context
        let contributors = contributors.map { (id: $0.id, isRequired: $0.isRequired, implementation: $0) }
        guard request.destination == .model(route), adapter.identity == route.adapter, request.userText.utf8.count <= 2_097_152,
              historyContext.messages.allSatisfy({ $0.role != .context }),
              currentTrace.messages.allSatisfy({ $0.role == .assistant || $0.role == .tool }),
              historyContext.sources.count <= 8_192, currentTrace.sources.count <= 8_192,
              Set(contributors.map(\.id)).count == contributors.count else {
            throw MiraError(.configuration, "The model context composition is invalid.")
        }
        var entries: [Entry] = []
        var omissions: [AgentContextOmission] = []
        var inherited = AgentContextBuild.orderedSources(historyContext.sources + currentTrace.sources + (frozenContext?.sources ?? []))
        while inherited.count > 8_192 {
            try Task.checkCancellation()
            guard !history.isEmpty else { throw MiraError(.contextLimit, "The model input exceeds its supported bounds.") }
            history = history.removingOldestExchange()
            historyContext = history.context
            inherited = AgentContextBuild.orderedSources(historyContext.sources + currentTrace.sources + (frozenContext?.sources ?? []))
        }
        for source in inherited { try source.validate() }
        if !inherited.isEmpty { try await authorizer.validate(inherited, for: request) }
        if let frozenContext {
            guard frozenContext.message.map({ $0.role == .context && $0.blocks.count == 1 }) ?? true,
                  frozenContext.evidence.count <= 128,
                  frozenContext.omissions.count <= 128,
                  frozenContext.sources.count <= 8_192 else {
                throw MiraError(.configuration, "The frozen context snapshot is invalid.")
            }
            for source in frozenContext.sources { try source.validate() }
            while true {
                do {
                    return try await fit(request: request, stepID: stepID, instructions: instructions,
                        history: historyContext, currentTrace: currentTrace, tools: tools,
                        route: route, adapter: adapter, authorizer: authorizer,
                        inherited: inherited, contextMessage: frozenContext.message,
                        fixedEvidence: frozenContext.evidence, entries: [], omissions: frozenContext.omissions)
                } catch let error as MiraError where error.code == .contextLimit && !history.isEmpty {
                    try Task.checkCancellation()
                    history = history.removingOldestExchange()
                    historyContext = history.context
                    inherited = AgentContextBuild.orderedSources(
                        historyContext.sources + currentTrace.sources + frozenContext.sources)
                    if !inherited.isEmpty { try await authorizer.validate(inherited, for: request) }
                }
            }
        }
        for contributor in contributors.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            guard SessionState.validIdentifier(contributor.id, maximumBytes: 128) else {
                throw MiraError(.configuration, "The context contributor identity is invalid.")
            }
            do {
                let items = try await contributor.implementation.contribute(to: request)
                try Task.checkCancellation()
                guard items.count <= 32, Set(items.map(\.id)).count == items.count,
                      entries.count + items.count <= 128 else {
                    throw MiraError(.invalidInput, "The context contribution exceeds its item limit.")
                }
                for item in items {
                    guard SessionState.validIdentifier(item.id, maximumBytes: 128),
                          item.text.utf8.count <= 65_536, item.sources.count <= 64 else {
                        throw MiraError(.invalidInput, "The context contribution exceeds its supported bounds.")
                    }
                    for source in item.sources { try source.validate() }
                }
                try await authorizer.validate(AgentContextBuild.orderedSources(items.flatMap(\.sources)), for: request)
                entries += items.map { .init(contributorID: contributor.id, item: $0, required: contributor.isRequired) }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if contributor.isRequired { throw error }
                let reason: AgentContextOmission.Reason
                switch (error as? MiraError)?.code {
                case .unauthorized: reason = .unauthorized
                case .invalidInput, .configuration, .outputLimit: reason = .invalid
                default: reason = .unavailable
                }
                omissions.append(.init(contributorID: contributor.id, itemID: nil, reason: reason))
            }
        }
        entries.sort {
            if $0.item.priority != $1.item.priority { return $0.item.priority > $1.item.priority }
            if $0.contributorID != $1.contributorID { return $0.contributorID < $1.contributorID }
            return $0.item.id < $1.item.id
        }

        // Contributions are collected exactly once for this step. Refit only these immutable values.
        while true {
            do {
                return try await fit(request: request, stepID: stepID, instructions: instructions,
                    history: historyContext, currentTrace: currentTrace, tools: tools,
                    route: route, adapter: adapter, authorizer: authorizer,
                    inherited: inherited, contextMessage: nil, fixedEvidence: nil,
                    entries: entries, omissions: omissions)
            } catch let error as MiraError where error.code == .contextLimit && !history.isEmpty {
                try Task.checkCancellation()
                history = history.removingOldestExchange()
                historyContext = history.context
                inherited = AgentContextBuild.orderedSources(historyContext.sources + currentTrace.sources)
                if !inherited.isEmpty { try await authorizer.validate(inherited, for: request) }
            }
        }
    }

    private func fit(request: AgentContextRequest, stepID: UUID, instructions: String,
                     history: AgentContextHistory, currentTrace: AgentContextHistory, tools: [ToolDefinition],
                     route: AgentModelRoute, adapter: any AgentModelAdapter, authorizer: any AgentSourceAuthorizer,
                     inherited: [AgentSourceReference], contextMessage: AgentModelMessage?,
                     fixedEvidence: [AgentContextEvidence]?, entries: [Entry], omissions: [AgentContextOmission]) async throws -> AgentContextBuild {
        // Transient pruning is local to one history candidate; only the accepted omissions are persisted.
        var entries = entries
        var omissions = omissions
        while true {
            try Task.checkCancellation()
            var messages = history.messages
            if let contextMessage {
                messages.append(contextMessage)
            } else if !entries.isEmpty {
                let bytes = try SessionCodec.encode(entries.map {
                    DataRecord(contributor: $0.contributorID, id: $0.item.id, text: $0.item.text, sources: $0.item.sources)
                })
                messages.append(.init(role: .context,
                                      blocks: [.init(id: "context", content: .text(String(decoding: bytes, as: UTF8.self)))]))
            }
            messages.append(.init(role: .user,
                                  blocks: [.init(id: "user", content: .text(request.userText))]))
            messages += currentTrace.messages
            let input = AgentModelInput(stepID: stepID, executionID: request.executionID,
                instructions: instructions, messages: messages, tools: tools)
            do {
                try input.validate(for: route)
                let prepared = try adapter.prepare(input, route: route)
                try Task.checkCancellation()
                // Adapters may encode the wire payload, but cannot silently replace the audited semantic input.
                guard prepared.input == input else {
                    throw MiraError(.malformedStream, "The model adapter changed the prepared semantic input.")
                }
                try prepared.validate(for: route)
                let evidence = fixedEvidence ?? entries.map { AgentContextEvidence(contributorID: $0.contributorID, itemID: $0.item.id, sources: $0.item.sources) }
                let build = AgentContextBuild(request: request, prepared: prepared, inheritedSources: inherited,
                    evidence: evidence, omissions: omissions)
                guard build.sources.count <= 8_192 else {
                    throw MiraError(.contextLimit, "The model input exceeds its supported bounds.")
                }
                try await authorizer.validate(build.sources, for: request)
                try Task.checkCancellation()
                return build
            } catch let error as MiraError where error.code == .contextLimit {
                guard let index = entries.lastIndex(where: { !$0.required }) else { throw error }
                let removed = entries.remove(at: index)
                omissions.append(.init(contributorID: removed.contributorID, itemID: removed.item.id, reason: .budget))
            }
        }
    }
}
