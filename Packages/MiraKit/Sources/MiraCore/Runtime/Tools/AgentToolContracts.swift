import Foundation

public struct AgentToolDescriptor: Codable, Sendable, Equatable {
    public let definition: ToolDefinition
    public let revision: Int
    public let outputSchema: JSONValue
    public let executionMode: ToolExecutionMode
    public let timeoutMilliseconds: Int
    public let maximumResultBytes: Int
    public init(definition: ToolDefinition, revision: Int, outputSchema: JSONValue,
                executionMode: ToolExecutionMode, timeoutMilliseconds: Int, maximumResultBytes: Int) {
        self.definition = definition; self.revision = revision; self.outputSchema = outputSchema
        self.executionMode = executionMode; self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumResultBytes = maximumResultBytes
    }
    public func validate() throws {
        guard SessionState.validIdentifier(definition.name, maximumBytes: 64), revision > 0,
              definition.inputSchema["type"] == .string("object"),
              !definition.description.isEmpty, definition.description.utf8.count <= 4_096,
              (1...120_000).contains(timeoutMilliseconds), (1...65_536).contains(maximumResultBytes),
              try SessionCodec.encode(self).count <= 65_536 else {
            throw MiraError(.configuration, "The tool descriptor is invalid or exceeds its limits.")
        }
        try ToolSchemaValidator.validateSchema(definition.inputSchema)
        try ToolSchemaValidator.validateSchema(outputSchema)
    }
}

/// Preparation may resolve concrete revisions, but never performs a mutation.
public struct AgentToolPlan: Codable, Sendable, Equatable {
    public let input: JSONValue
    /// Sources selected by this tool. Inherited model context remains on the
    /// committed request and is authorized separately by the execution runtime.
    public let sources: [AgentSourceReference]
    public let targets: [AgentSourceReference]
    public init(input: JSONValue, sources: [AgentSourceReference], targets: [AgentSourceReference]) {
        self.input = input; self.sources = sources; self.targets = targets
    }
    public func validate() throws {
        guard sources.count <= 8_192, targets.count <= 128,
              Set(targets).count == targets.count,
              try SessionCodec.encode(self).count <= 1_048_576 else {
            throw MiraError(.invalidInput, "The prepared tool plan exceeds its supported bounds.")
        }
        for source in sources + targets { try source.validate() }
    }
}

public struct AgentToolContext: Sendable {
    public let executionID: ExecutionID
    public let invocationID: UUID
    /// Original journal evidence, including its exact body reference and admission identity.
    /// A retry changes the executing turn, never the evidence's original date, time zone or identity.
    public let evidence: SessionUserEvidence
    /// The admitted route is provenance for domain policy checks, not proof of current permission.
    public let route: AgentModelRoute

    init(executionID: ExecutionID, invocationID: UUID, evidence: SessionUserEvidence, route: AgentModelRoute) {
        self.executionID = executionID; self.invocationID = invocationID
        self.evidence = evidence; self.route = route
    }
}

public protocol AgentToolPreparation: Sendable {
    var descriptor: AgentToolDescriptor { get }
    /// Explicitly declares whether this contribution adds restrictions to the host policy.
    /// Module policy can require additional approval or deny, but cannot override host denial.
    var policy: AgentToolPolicyRequirement { get }
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan
}

public protocol AgentReadTool: AgentToolPreparation {
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue
}

/// Local writes describe a registered business command. Only the transaction owner executes it.
public protocol AgentLocalWriteTool: AgentToolPreparation {
    var businessNamespace: String { get }
}

public protocol AgentExternalWriteTool: AgentToolPreparation {
    /// Cancellation is cooperative. A missing result after dispatch leaves the external effect unknown.
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue
}

public enum AgentTool: Sendable {
    case read(any AgentReadTool)
    case localWrite(any AgentLocalWriteTool)
    case externalWrite(any AgentExternalWriteTool)

    public var preparation: any AgentToolPreparation {
        switch self { case .read(let value): value; case .localWrite(let value): value; case .externalWrite(let value): value }
    }
    public var effect: SessionEffectKind {
        switch self { case .read: .read; case .localWrite: .localWrite; case .externalWrite: .externalWrite }
    }
    public var businessNamespace: String? {
        if case .localWrite(let value) = self { return value.businessNamespace }; return nil
    }
}

public struct AgentToolProposal: Codable, Sendable, Equatable {
    public let descriptor: AgentToolDescriptor
    public let effect: SessionEffectKind
    public let businessNamespace: String?
    public let callDigest: String
    public let plan: AgentToolPlan
    public init(descriptor: AgentToolDescriptor, effect: SessionEffectKind, businessNamespace: String?,
                callDigest: String, plan: AgentToolPlan) {
        self.descriptor = descriptor; self.effect = effect; self.businessNamespace = businessNamespace
        self.callDigest = callDigest; self.plan = plan
    }
    public func validate() throws {
        try descriptor.validate(); try plan.validate()
        guard Self.isDigest(callDigest), (effect == .localWrite) == (businessNamespace != nil),
              businessNamespace.map({ SessionState.validIdentifier($0, maximumBytes: 128) }) ?? true else {
            throw MiraError(.invalidInput, "The tool proposal identity is invalid.")
        }
    }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum AgentToolPolicyDecision: Sendable {
    case allow
    case deny
    case requireApproval(prompt: String, expiresAt: Date)
}

public protocol AgentToolPolicy: Sendable {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision
    /// Called after approval and immediately before dispatch. It must recheck current host restrictions.
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws
}

public enum AgentToolPolicyRequirement: Sendable {
    case hostOnly
    case constrained(any AgentToolPolicy)
}

public protocol AgentEffectAuthority: Sendable {
    func authorization(for proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentLibraryAuthorization
    func validate(_ authorization: AgentLibraryAuthorization, proposal: AgentToolProposal, context: AgentToolContext) async throws
}

/// A journal-owned identity. Business adapters must resolve it against the durable journal before committing.
public struct AgentEffectProof: Codable, Sendable, Equatable {
    public let sessionID: ConversationID
    public let executionID: ExecutionID
    public let invocationID: UUID
    public let intentBatchID: UUID
    public let intentSequence: Int64
    public let authorization: AgentLibraryAuthorization
    public let proposal: SessionContent
    public init(sessionID: ConversationID, executionID: ExecutionID, invocationID: UUID,
                intentBatchID: UUID, intentSequence: Int64, authorization: AgentLibraryAuthorization,
                proposal: SessionContent) {
        self.sessionID = sessionID; self.executionID = executionID; self.invocationID = invocationID
        self.intentBatchID = intentBatchID; self.intentSequence = intentSequence
        self.authorization = authorization; self.proposal = proposal
    }
}

public struct AgentBusinessReceiptReference: Codable, Sendable, Equatable {
    public let id: UUID
    public let invocationID: UUID
    public let authorization: AgentLibraryAuthorization
    public let intentDigest: String
    public let resultDigest: String
    public init(id: UUID, invocationID: UUID, authorization: AgentLibraryAuthorization, intentDigest: String, resultDigest: String) {
        self.id = id; self.invocationID = invocationID; self.authorization = authorization
        self.intentDigest = intentDigest; self.resultDigest = resultDigest
    }
    public func validate() throws {
        guard AgentToolProposal.isDigest(intentDigest), AgentToolProposal.isDigest(resultDigest) else {
            throw MiraError(.storage, "The business receipt digest is invalid.")
        }
    }
}

public struct AgentBusinessReceipt: Codable, Sendable, Equatable {
    public let reference: AgentBusinessReceiptReference
    /// Canonical encoded JSON result owned by the committed business operation.
    public let result: Data
    public init(reference: AgentBusinessReceiptReference, result: Data) { self.reference = reference; self.result = result }
}

public enum AgentBusinessCommitOutcome: Sendable, Equatable {
    case committed(AgentBusinessReceipt)
    case notCommitted(MiraError)
    case indeterminate(MiraError)
}

public enum AgentBusinessReceiptLookup: Sendable, Equatable {
    case committed(AgentBusinessReceipt)
    /// Only after the transaction owner has drained the original operation and excluded another writer.
    case absent
    case unavailable(MiraError)
}

public struct AgentReceiptPublication: Sendable, Equatable {
    public let proof: AgentEffectProof
    public let receipt: AgentBusinessReceipt
    public init(proof: AgentEffectProof, receipt: AgentBusinessReceipt) { self.proof = proof; self.receipt = receipt }
}

public protocol AgentBusinessReceipts: Sendable {
    /// Fences future local commits for this execution and drains any transaction already ahead of the fence.
    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws
    /// Never executes the command. A missing or deleted result body cannot erase the receipt identity.
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication]
    /// Must verify that the referenced durable journal prefix contains this receipt's matching tool resolution.
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws
}

public protocol AgentBusinessEffects: AgentBusinessReceipts {
    /// Validates journal intent, source/target revisions and epoch, then atomically writes the domain change, receipt and outbox.
    func commit(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome
}

public struct AgentResolvedEffect: Sendable {
    public let proposal: AgentToolProposal
    public let context: AgentToolContext
    public init(proposal: AgentToolProposal, context: AgentToolContext) { self.proposal = proposal; self.context = context }
}

public protocol AgentEffectIntentResolver: Sendable {
    /// For a new commit, require a dispatched, unsettled, currently eligible intent. For recovery, only verify its durable identity.
    func resolve(_ proof: AgentEffectProof, requireEligible: Bool) async throws -> AgentResolvedEffect
    func validatePublication(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws
}
