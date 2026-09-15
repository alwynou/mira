import Foundation
import MiraCore

/// Reads model IDs from OpenAI-compatible and Anthropic model-list endpoints.
///
/// The route and authentication shape follow the official API references:
/// - OpenAI Models: https://developers.openai.com/api/reference/resources/models/methods/list
/// - Anthropic List Models: https://platform.claude.com/docs/en/api/models/list
///
/// Discovery is intentionally bounded. Each page is at most 2 MiB, the whole
/// operation is at most 8 MiB, Anthropic pagination is at most 10 pages and
/// the returned set is at most 2,000 models. AgentModelDiscoveryService owns the
/// operation deadline; the transport owns lower-level connect and resource limits.
public struct HTTPModelDiscovery: AgentModelDiscoveryProvider {
    public let protocolKind: HTTPModelDiscoveryProtocol
    public var identity: AgentAdapterIdentity { protocolKind.identity }
    public let credentials: any CredentialReader
    public let transport: any HTTPStreamingTransport

    public init(
        protocolKind: HTTPModelDiscoveryProtocol,
        credentials: any CredentialReader,
        transport: any HTTPStreamingTransport = URLSessionStreamingTransport()
    ) {
        self.protocolKind = protocolKind
        self.credentials = credentials
        self.transport = transport
    }

    public func descriptor() throws -> AgentModelDiscoveryDescriptor {
        .init(
            adapter: identity,
            title: protocolKind == .anthropic ? "Anthropic model discovery" : "OpenAI model discovery",
            credential: .required, connection: HTTPConnectionSettings.schema)
    }

    public func discover(connection: AgentConfiguredConnection) -> AgentModelDiscoveryOperation {
        let producer = Task {
            try Task.checkCancellation()
            try descriptor().validate(connection)
            let endpointRecord = try connection.discoveryEndpoint
            let settings = try SessionCodec.decode(
                HTTPConnectionSettings.self, from: SessionCodec.encode(endpointRecord.configuration.value))
            let endpoint = try HTTPModelConfiguration(
                baseURL: settings.baseURL, allowsLoopbackHTTP: settings.allowsLoopbackHTTP,
                protocolID: protocolKind == .anthropic ? .anthropicMessages : .chatCompletions,
                dialectProfileID: protocolKind == .anthropic ? .anthropic : .generic
            ).validatedEndpoint()
            do {
                return try await fetchModels(credential: endpointRecord.credential, endpoint: endpoint)
            } catch { throw safeDiscoveryError(error) }
        }
        // The producer closes every transport operation before returning, even after cancellation.
        return AgentModelDiscoveryOperation(producer: producer, cancelAndDrain: {})
    }

    private func fetchModels(credential: AgentCredentialReference?, endpoint: URL) async throws
        -> [AgentDiscoveredModel]
    {
        // Anthropic's validated endpoint is /.../v1/messages, while an
        // OpenAI-compatible endpoint is /.../chat/completions. Remove the
        // operation component in each protocol; OpenAI also removes its
        // chat resource component so /api/v1 remains /api/v1/models.
        let modelEndpoint: URL
        if protocolKind == .anthropic {
            modelEndpoint = endpoint.deletingLastPathComponent().appendingPathComponent("models")
        } else {
            modelEndpoint =
                endpoint
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("models")
        }
        try Task.checkCancellation()
        let secret: String
        do {
            guard let credential else { throw DiscoveryError.credentialMissing }
            secret = try credentials.read(reference: credential.reference, version: credential.version)
        } catch {
            throw DiscoveryError.credentialMissing
        }
        guard !secret.isEmpty, !secret.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DiscoveryError.credentialMissing
        }
        try Task.checkCancellation()

        return try await collect(endpoint: modelEndpoint, secret: secret)
    }

    private func collect(
        endpoint: URL,
        secret: String,
    ) async throws -> [AgentDiscoveredModel] {
        var all: [String: AgentDiscoveredModel] = [:]
        var afterID: String?
        var page = 0
        var totalBytes = 0
        var seenCursors = Set<String>()

        while true {
            try Task.checkCancellation()
            page += 1
            guard page <= Limits.maxPages else { throw DiscoveryError.resourceLimit }

            let request = try makeRequest(endpoint: endpoint, secret: secret, afterID: afterID)
            let body = try await readPage(request: request, totalBytes: totalBytes)
            totalBytes += body.count
            let decoded = try decodePage(body)

            for providerModel in decoded.models {
                let model = try makeDiscoveredModel(providerModel)
                if let existing = all[model.id] {
                    // Select the lexicographically smallest valid name so
                    // duplicate handling is independent of page ordering.
                    let selectedName = [existing.displayName, model.displayName]
                        .compactMap { $0 }
                        .min()
                    all[model.id] = AgentDiscoveredModel(id: model.id, displayName: selectedName)
                } else {
                    all[model.id] = model
                }
                guard all.count <= Limits.maxModels else { throw DiscoveryError.resourceLimit }
            }

            guard protocolKind == .anthropic else { break }
            guard let hasMore = decoded.hasMore else { throw DiscoveryError.malformed }
            guard hasMore else { break }
            guard let next = decoded.lastID, isValidModelID(next), seenCursors.insert(next).inserted else {
                throw DiscoveryError.malformed
            }
            afterID = next
        }

        return all.values.sorted { $0.id < $1.id }
    }

    private func makeRequest(
        endpoint: URL,
        secret: String,
        afterID: String?
    ) throws -> URLRequest {
        var url = endpoint
        if protocolKind == .anthropic, let afterID {
            guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                throw DiscoveryError.malformed
            }
            components.queryItems = [
                URLQueryItem(name: "limit", value: String(Limits.anthropicPageSize)),
                URLQueryItem(name: "after_id", value: afterID),
            ]
            guard let paged = components.url else { throw DiscoveryError.malformed }
            url = paged
        } else if protocolKind == .anthropic {
            guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                throw DiscoveryError.malformed
            }
            components.queryItems = [URLQueryItem(name: "limit", value: String(Limits.anthropicPageSize))]
            guard let paged = components.url else { throw DiscoveryError.malformed }
            url = paged
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Mira-Request-ID")
        if protocolKind == .openAI {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    private func readPage(request: URLRequest, totalBytes: Int) async throws -> Data {
        var responseReceived = false
        var ended = false
        var bytes = Data()
        let operation = transport.stream(request: request)
        do {
            readLoop: for try await event in operation.events {
                try Task.checkCancellation()
                switch event {
                case .response(let response):
                    guard !responseReceived, !ended else { throw DiscoveryError.malformed }
                    responseReceived = true
                    guard (200..<300).contains(response.statusCode) else {
                        throw DiscoveryError.status(response.statusCode)
                    }
                case .bytes(let chunk):
                    guard responseReceived, !ended else { throw DiscoveryError.malformed }
                    guard chunk.count <= Limits.maxPageBytes else { throw DiscoveryError.resourceLimit }
                    guard bytes.count <= Limits.maxPageBytes - chunk.count else { throw DiscoveryError.resourceLimit }
                    guard totalBytes <= Limits.maxTotalBytes - bytes.count - chunk.count else {
                        throw DiscoveryError.resourceLimit
                    }
                    bytes.append(chunk)
                case .end:
                    guard responseReceived, !ended else { throw DiscoveryError.malformed }
                    ended = true
                    // A transport may keep the underlying HTTP task alive
                    // after yielding its terminal event. Stop this exact
                    // request once the complete page has arrived.
                    break readLoop
                }
            }
        } catch {
            await operation.close()
            throw error
        }
        guard responseReceived, ended else {
            await operation.close()
            throw DiscoveryError.prematureEOF
        }
        await operation.close()
        return bytes
    }

    private func decodePage(_ data: Data) throws -> ModelPage {
        guard !data.isEmpty else { throw DiscoveryError.malformed }
        do {
            return try JSONDecoder().decode(ModelPage.self, from: data)
        } catch {
            throw DiscoveryError.malformed
        }
    }

    private func makeDiscoveredModel(_ value: ProviderModel) throws -> AgentDiscoveredModel {
        guard isValidModelID(value.id) else { throw DiscoveryError.malformed }
        let displayName: String?
        if let raw = value.displayName, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            raw.utf8.count <= Limits.maxModelIDBytes,
            !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        {
            displayName = raw
        } else {
            displayName = nil
        }
        return AgentDiscoveredModel(id: value.id, displayName: displayName)
    }

    private func isValidModelID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= Limits.maxModelIDBytes else { return false }
        return !id.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

extension HTTPModelDiscovery {
    fileprivate enum Limits {
        static let maxPages = 10
        static let maxModels = 2_000
        static let maxPageBytes = 2 * 1024 * 1024
        static let maxTotalBytes = 8 * 1024 * 1024
        static let maxModelIDBytes = 512
        static let anthropicPageSize = 1_000
    }

    fileprivate struct ProviderModel: Decodable {
        let id: String
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    fileprivate struct ModelPage: Decodable {
        let models: [ProviderModel]
        let hasMore: Bool?
        let lastID: String?

        enum CodingKeys: String, CodingKey {
            case models = "data"
            case hasMore = "has_more"
            case lastID = "last_id"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            models = try values.decode([ProviderModel].self, forKey: .models)
            hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore)
            lastID = try values.decodeIfPresent(String.self, forKey: .lastID)
        }
    }

    fileprivate enum DiscoveryError: Error {
        case credentialMissing
        case malformed
        case prematureEOF
        case resourceLimit
        case status(Int)
    }

}

private func safeDiscoveryError(_ error: any Error) -> MiraError {
    if error is CancellationError { return MiraError(.cancelled, "Model discovery was stopped.") }
    if let error = error as? HTTPModelDiscovery.DiscoveryError {
        switch error {
        case .credentialMissing:
            return MiraError(.credentialMissing, "The provider credential is unavailable.")
        case .malformed:
            return MiraError(.malformedStream, "The provider returned an unparseable model list.")
        case .prematureEOF:
            return MiraError(.interrupted, "The provider connection ended before model discovery completed.")
        case .resourceLimit:
            return MiraError(.outputLimit, "The provider model list exceeded its safety limits.")
        case .status(let status):
            switch status {
            case 401, 403: return MiraError(.unauthorized, "The provider credential was rejected.")
            case 429: return MiraError(.rateLimited, "Too many requests; try again later.")
            case 500...599: return MiraError(.network, "The provider is temporarily unavailable; try again later.")
            default: return MiraError(.providerRejected, "The provider rejected model discovery.")
            }
        }
    }
    if let error = error as? URLError {
        if error.code == .cancelled { return MiraError(.cancelled, "Model discovery was stopped.") }
        if error.code == .timedOut { return MiraError(.timeout, "Model discovery timed out.") }
    }
    return MiraError(.network, "Unable to connect to the provider; try again later.")
}

/// HTTP wire choices remain in the adapter module, never in the agent core.
public enum HTTPModelDiscoveryProtocol: String, Codable, CaseIterable, Sendable {
    case openAI, anthropic
    public var identity: AgentAdapterIdentity {
        .init(id: self == .anthropic ? "mira.http.discovery.anthropic" : "mira.http.discovery.openai", revision: 1)
    }
}
