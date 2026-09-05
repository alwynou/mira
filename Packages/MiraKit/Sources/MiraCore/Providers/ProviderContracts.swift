import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable { case openAICompatible, anthropic }
public enum CapabilityState: String, Codable, Sendable { case unknown, declared, verified, failed }

/// Non-secret configuration. A copy is frozen in each execution before context construction.
public struct ModelRoute: Identifiable, Codable, Sendable, Equatable {
    public var id: RouteID
    public var revision: Int
    public var name: String
    public var providerKind: ProviderKind
    public var baseURL: String
    public var modelID: String
    public var credentialReference: String
    public var credentialVersion: Int
    public var contextWindow: Int?
    public var maxOutputTokens: Int
    public var textCapability: CapabilityState
    public var allowsLoopbackHTTP: Bool
    public var requestsUsage: Bool
    public init(id: RouteID = RouteID(), revision: Int = 1, name: String, providerKind: ProviderKind, baseURL: String, modelID: String, credentialReference: String, credentialVersion: Int = 1, contextWindow: Int? = nil, maxOutputTokens: Int = 1024, textCapability: CapabilityState = .declared, allowsLoopbackHTTP: Bool = false, requestsUsage: Bool = true) {
        self.id = id; self.revision = revision; self.name = name; self.providerKind = providerKind
        self.baseURL = baseURL; self.modelID = modelID; self.credentialReference = credentialReference
        self.credentialVersion = credentialVersion; self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens; self.textCapability = textCapability
        self.allowsLoopbackHTTP = allowsLoopbackHTTP; self.requestsUsage = requestsUsage
    }

    public func validatedEndpoint() throws -> URL {
        guard let components = URLComponents(string: baseURL), let host = components.host?.lowercased(),
              !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw MiraError(.configuration, "请填写不含凭据、查询参数或片段的服务地址。")
        }
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        guard components.scheme == "https" || (components.scheme == "http" && loopback && allowsLoopbackHTTP) else {
            throw MiraError(.configuration, "服务地址需要 HTTPS；本机 HTTP 服务须明确启用。")
        }
        guard var url = components.url else { throw MiraError(.configuration, "服务地址无效。") }
        if url.path.hasSuffix("/chat/completions") || url.path.hasSuffix("/messages") {
            throw MiraError(.configuration, "请填写 Base URL，不要包含 chat/completions 或 messages。")
        }
        if providerKind == .anthropic && !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("v1") {
            url.appendPathComponent("v1")
        }
        url.appendPathComponent(providerKind == .anthropic ? "messages" : "chat/completions")
        return url
    }

    public func validateForSending() throws {
        _ = try validatedEndpoint()
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MiraError(.configuration, "请填写 Model ID。") }
        guard let window = contextWindow, window > 0, window <= 10_000_000,
              maxOutputTokens > 0, maxOutputTokens < window else { throw MiraError(.configuration, "请配置有效的上下文窗口与最大输出 Token 数。") }
        guard textCapability == .declared || textCapability == .verified else { throw MiraError(.configuration, "请确认此模型支持流式文本对话。") }
    }
}

public struct CanonicalMessage: Codable, Sendable, Equatable {
    public var role: MessageRole
    public var text: String
    public init(role: MessageRole, text: String) { self.role = role; self.text = text }
}
public struct CanonicalModelRequest: Codable, Sendable, Equatable {
    public var executionID: ExecutionID
    public var system: String
    public var messages: [CanonicalMessage]
    public init(executionID: ExecutionID, system: String, messages: [CanonicalMessage]) {
        self.executionID = executionID; self.system = system; self.messages = messages
    }
}
public enum StreamFinishReason: String, Sendable { case stop, outputLimit }
public enum CanonicalStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case usage(TokenUsage)
    case finished(StreamFinishReason)
}

public protocol CredentialReader: Sendable {
    /// Read at dispatch time. Implementations must enforce reference/version identity.
    func read(reference: String, version: Int) throws -> String
}
public protocol ModelProviderPort: Sendable {
    /// The consumer task cancellation must cancel its URLSession task. EOF without a protocol terminal event is an error.
    func stream(request: CanonicalModelRequest, route: ModelRoute) -> AsyncThrowingStream<CanonicalStreamEvent, any Error>
}
