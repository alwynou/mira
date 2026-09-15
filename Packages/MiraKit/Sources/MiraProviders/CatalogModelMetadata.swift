import Foundation
import MiraCore

/// The task classification stored in the advisory provider catalog.
public enum CatalogModelTask: String, Codable, Sendable {
    case textGeneration
    case embedding
    case imageGeneration
    case audio
    case unknown
}

public struct CatalogReasoningOption: Codable, Sendable, Equatable {
    public let type: String
    public let values: [String]?
    public let min: Int?
    public let max: Int?
    public init(type: String, values: [String]? = nil, min: Int? = nil, max: Int? = nil) {
        self.type = type; self.values = values; self.min = min; self.max = max
    }
    public func validate() throws {
        guard ["toggle", "effort", "budget_tokens"].contains(type),
            values.map({ $0.count <= 32 && Set($0).count == $0.count && $0.allSatisfy { ($0.utf8.count <= 64 && (try? AgentConfigurationIdentity(id: $0, revision: 1).validate()) != nil) } }) ?? true,
            min.map({ (-1...10_000_000).contains($0) }) ?? true,
            max.map({ (0...10_000_000).contains($0) }) ?? true else {
            throw MiraError(.configuration, "The catalog reasoning control is invalid.")
        }
    }
}

/// Provider-owned metadata copied from the catalog source. It bounds UI and
/// configuration hints; it never claims that a configured endpoint is verified.
public struct CatalogModelMetadata: Codable, Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let displayName: String?
    public let sourceURL: String
    public let sourceRevision: String
    public let retrievedAt: String
    public let baseModelID: String?
    public let lifecycle: String?
    public let reasoningOptions: [CatalogReasoningOption]
    public let maxInputTokens: Int?
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let inputModalities: [String]
    public let outputModalities: [String]
    public let toolCall: Bool?
    public let structuredOutput: Bool?
    public let reasoning: Bool?
    public let requiresReasoningContinuation: Bool
    public let task: CatalogModelTask
    public let pricing: ModelPricing?

    public init(
        providerID: String, modelID: String, displayName: String? = nil, sourceURL: String,
        sourceRevision: String, retrievedAt: String, contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil, inputModalities: [String] = [],
        outputModalities: [String] = [], toolCall: Bool? = nil,
        structuredOutput: Bool? = nil, reasoning: Bool? = nil,
        requiresReasoningContinuation: Bool = false, task: CatalogModelTask = .unknown,
        pricing: ModelPricing? = nil, baseModelID: String? = nil, lifecycle: String? = nil,
        reasoningOptions: [CatalogReasoningOption] = [], maxInputTokens: Int? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.retrievedAt = retrievedAt
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.toolCall = toolCall
        self.structuredOutput = structuredOutput
        self.reasoning = reasoning
        self.requiresReasoningContinuation = requiresReasoningContinuation
        self.task = task
        self.pricing = pricing
        self.baseModelID = baseModelID; self.lifecycle = lifecycle
        self.reasoningOptions = reasoningOptions; self.maxInputTokens = maxInputTokens
    }

    public func validate() throws {
        try pricing?.validate()
        for option in reasoningOptions { try option.validate() }
        guard reasoningOptions.count <= 8,
            baseModelID.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
            lifecycle.map({ ($0.utf8.count <= 64 && (try? AgentConfigurationIdentity(id: $0, revision: 1).validate()) != nil) }) ?? true,
            maxInputTokens.map({ (1...10_000_000).contains($0) }) ?? true,
            !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            providerID.count <= 300,
            !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            modelID.count <= 300,
            !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            sourceURL.count <= 2_048,
            !sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            sourceRevision.count <= 300,
            !retrievedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            retrievedAt.count <= 100,
            displayName.map({ $0.count <= 300 }) ?? true,
            inputModalities.count <= 32,
            outputModalities.count <= 32,
            (inputModalities + outputModalities).allSatisfy({ !$0.isEmpty && $0.count <= 32 }),
            contextWindow.map({ $0 > 0 && $0 <= 10_000_000 }) ?? true,
            maxOutputTokens.map({ $0 > 0 && $0 <= 10_000_000 }) ?? true
        else {
            throw MiraError(.configuration, "The provider model catalog metadata is invalid.")
        }
    }
}
