import Foundation

public enum CapabilityState: String, Codable, Sendable { case unknown, declared, verified, failed }

public enum CanonicalRole: String, Codable, Sendable {
    case user, assistant, tool
    /// Turn-scoped application data. Adapters send it as untrusted user-level
    /// context, never as system instructions or a persisted user message.
    case context
}

public enum StreamFinishReason: String, Codable, Sendable { case stop, outputLimit, toolCalls }
