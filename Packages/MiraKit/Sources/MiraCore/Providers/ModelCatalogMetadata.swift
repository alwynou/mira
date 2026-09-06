import Foundation

public enum ModelCatalogTask: String, Codable, Sendable {
    case textGeneration
    case embedding
    case imageGeneration
    case audio
    case unknown
}

/// Advisory metadata copied from a provider catalog. It bounds configured
/// model settings; it does not verify the provider or replace an explicit
/// capability probe.
public struct ModelCatalogMetadata: Codable, Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let displayName: String?
    public let sourceURL: String
    public let sourceRevision: String
    public let retrievedAt: String
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let inputModalities: [String]
    public let outputModalities: [String]
    public let toolCall: Bool?
    public let structuredOutput: Bool?
    public let reasoning: Bool?
    public let requiresReasoningContinuation: Bool
    public let task: ModelCatalogTask

    public init(providerID: String, modelID: String, displayName: String? = nil, sourceURL: String, sourceRevision: String, retrievedAt: String, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, inputModalities: [String] = [], outputModalities: [String] = [], toolCall: Bool? = nil, structuredOutput: Bool? = nil, reasoning: Bool? = nil, requiresReasoningContinuation: Bool = false, task: ModelCatalogTask = .unknown) {
        self.providerID = providerID; self.modelID = modelID; self.displayName = displayName
        self.sourceURL = sourceURL; self.sourceRevision = sourceRevision; self.retrievedAt = retrievedAt
        self.contextWindow = contextWindow; self.maxOutputTokens = maxOutputTokens
        self.inputModalities = inputModalities; self.outputModalities = outputModalities
        self.toolCall = toolCall; self.structuredOutput = structuredOutput; self.reasoning = reasoning
        self.requiresReasoningContinuation = requiresReasoningContinuation; self.task = task
    }

    public func validate() throws {
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
              inputModalities.count <= 32, outputModalities.count <= 32,
              (inputModalities + outputModalities).allSatisfy({ !$0.isEmpty && $0.count <= 32 }),
              contextWindow.map({ $0 > 0 && $0 <= 10_000_000 }) ?? true,
              maxOutputTokens.map({ $0 > 0 && $0 <= 10_000_000 }) ?? true else {
            throw MiraError(.configuration, "The provider model catalog metadata is invalid.")
        }
    }
}
