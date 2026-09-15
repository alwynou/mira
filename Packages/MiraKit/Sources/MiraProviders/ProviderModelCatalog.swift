import Foundation
import MiraCore

/// A checked-in, advisory provider/model catalog. It never writes configuration,
/// performs discovery, or upgrades a capability to verified status.
public struct ProviderModelCatalog: Sendable {
    public let providers: [CatalogProvider]
    private let providerIndex: [CanonicalAddress: [Int]]
    private let directoryProviderIndexes: [Int]

    public var directoryProviders: [CatalogProvider] {
        directoryProviderIndexes.map { providers[$0] }
    }

    public func displayName(for connection: AgentConfiguredConnection) -> String {
        guard let provider = matchingProvider(for: connection),
            ["moonshotai-cn", "kimi-for-coding"].contains(provider.directoryID)
        else {
            return connection.name
        }
        return provider.name
    }

    public static let bundled: ProviderModelCatalog = {
        guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let catalog = try? ProviderModelCatalog(data: data)
        else {
            fatalError("The bundled model catalog is missing or malformed.")
        }
        return catalog
    }()

    public init(data: Data) throws {
        do {
            let document = try JSONDecoder().decode(CatalogDocument.self, from: data)
            try document.validate()
            let providers = document.providers.map(CatalogProvider.init)
            self.providers = providers
            self.providerIndex = Self.makeProviderIndex(providers)
            self.directoryProviderIndexes = Self.makeDirectoryProviderIndexes(providers)
        } catch let error as ProviderModelCatalogError {
            throw error
        } catch {
            throw ProviderModelCatalogError.malformed
        }
    }

    /// Endpoint matching is advisory. The configured model's
    /// execution protocol is deliberately independent of this display lookup.
    public func matchingProvider(for connection: AgentConfiguredConnection, endpointID: String? = nil) -> CatalogProvider? {
        let selectedID = endpointID ?? connection.defaultInvocation?.endpointID ?? connection.discovery?.endpointID
        let endpoint = selectedID.flatMap { id in connection.endpoints.first { $0.id == id } }
            ?? (selectedID == nil && connection.endpoints.count == 1 ? connection.endpoints.first : nil)
        guard (try? connection.validate()) != nil,
            let endpoint, (try? HTTPConnectionSettings.schema.validate(endpoint.configuration)) != nil,
            let settings = try? SessionCodec.decode(
                HTTPConnectionSettings.self,
                from: SessionCodec.encode(endpoint.configuration.value)
            ),
            let address = CanonicalAddress(settings.baseURL),
            let indexes = providerIndex[address]
        else {
            return nil
        }
        return indexes.first.map { providers[$0] }
    }

    public func models(for connection: AgentConfiguredConnection) -> [CatalogModel] {
        matchingProvider(for: connection)?.models ?? []
    }

    public func model(for connection: AgentConfiguredConnection, modelID: String, endpointID: String? = nil) -> CatalogModel? {
        matchingProvider(for: connection, endpointID: endpointID)?.model(id: modelID)
    }

    private static func makeProviderIndex(_ providers: [CatalogProvider]) -> [CanonicalAddress: [Int]] {
        var index: [CanonicalAddress: [Int]] = [:]
        for (providerIndex, provider) in providers.enumerated() {
            guard let address = CanonicalAddress(provider.baseURL) else { continue }
            append(providerIndex, to: &index, key: address)
            if provider.id == "deepseek" {
                append(providerIndex, to: &index, key: address.withPath(address.path + "/v1"))
            }
        }
        return index
    }

    private static func makeDirectoryProviderIndexes(_ providers: [CatalogProvider]) -> [Int] {
        var seen = Set<String>()
        return providers.indices.filter { seen.insert(providers[$0].directoryID).inserted }
    }

    private static func append(_ index: Int, to indexByKey: inout [CanonicalAddress: [Int]], key: CanonicalAddress) {
        indexByKey[key, default: []].append(index)
    }
}

public struct CatalogProvider: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let documentationURL: String
    public let discoveryProtocol: HTTPModelDiscoveryProtocol
    public let protocolID: HTTPProtocolID
    public let dialectProfileID: HTTPDialectProfileID
    public let models: [CatalogModel]
    private let modelIndex: [String: Int]

    public var directoryID: String { id == "moonshotai" ? "moonshotai-cn" : id }

    public var defaultTestModelID: String? {
        switch directoryID {
        case "kimi-for-coding": "kimi-for-coding"
        case "moonshotai-cn": "kimi-k2.6"
        default: nil
        }
    }

    fileprivate init(_ value: CatalogDocument.Provider) {
        id = value.id
        name = value.name
        baseURL = value.baseURL
        documentationURL = value.documentationURL
        discoveryProtocol = value.discoveryProtocol
        protocolID = value.protocolID; dialectProfileID = value.dialectProfileID
        let models = value.models.map(CatalogModel.init)
        self.models = models
        self.modelIndex = Dictionary(uniqueKeysWithValues: models.enumerated().map { ($0.element.id, $0.offset) })
    }

    public func model(id: String) -> CatalogModel? {
        modelIndex[id].map { models[$0] }
    }
}

public struct CatalogModel: Identifiable, Sendable {
    public let id: String
    public let metadata: CatalogModelMetadata
    public let protocolID: HTTPProtocolID
    public let dialectProfileID: HTTPDialectProfileID
    public var suggestedAdapter: AgentAdapterIdentity? { try? protocolID.adapterIdentity }

    public init(metadata: CatalogModelMetadata, protocolID: HTTPProtocolID, dialectProfileID: HTTPDialectProfileID) {
        self.id = metadata.modelID; self.metadata = metadata
        self.protocolID = protocolID; self.dialectProfileID = dialectProfileID
    }
    fileprivate init(_ value: CatalogDocument.Model) {
        self.init(metadata: value.metadata, protocolID: value.protocolID, dialectProfileID: value.dialectProfileID)
    }
}

public enum ProviderModelCatalogError: Error, Equatable, Sendable {
    case malformed
}

private struct CatalogDocument: Decodable {
    let providers: [Provider]

    struct Provider: Decodable {
        let id: String
        let name: String
        let baseURL: String
        let documentationURL: String
        let discoveryProtocol: HTTPModelDiscoveryProtocol
        let protocolID: HTTPProtocolID
        let dialectProfileID: HTTPDialectProfileID
        let models: [Model]

        enum CodingKeys: String, CodingKey {
            case id, name, baseURL, documentationURL, discoveryProtocol, protocolID, dialectProfileID, models
        }
    }

    struct Model: Decodable {
        let metadata: CatalogModelMetadata
        let protocolID: HTTPProtocolID
        let dialectProfileID: HTTPDialectProfileID

        enum CodingKeys: String, CodingKey { case metadata, protocolID, dialectProfileID }
    }

    func validate() throws {
        guard !providers.isEmpty, providers.count <= 32 else { throw ProviderModelCatalogError.malformed }
        var providerIDs = Set<String>()
        for provider in providers {
            guard validToken(provider.id), providerIDs.insert(provider.id).inserted,
                validDisplayText(provider.name, maximum: 100),
                validHTTPSURL(provider.baseURL), CanonicalAddress(provider.baseURL) != nil,
                validHTTPSURL(provider.documentationURL), provider.models.count <= 2_000
            else {
                throw ProviderModelCatalogError.malformed
            }
            try provider.protocolID.validate(); try provider.dialectProfileID.validate()
            var modelIDs = Set<String>()
            for model in provider.models {
                try model.protocolID.validate(); try model.dialectProfileID.validate()
                let metadata = model.metadata
                guard (try? metadata.validate()) != nil,
                    metadata.providerID == provider.id,
                    validToken(metadata.modelID), modelIDs.insert(metadata.modelID).inserted,
                    validOptionalDisplayText(metadata.displayName),
                    validHTTPSURL(metadata.sourceURL),
                    validDisplayText(metadata.sourceRevision, maximum: 200),
                    validDisplayText(metadata.retrievedAt, maximum: 100),
                    metadata.contextWindow.map(validPositiveBound) ?? true,
                    metadata.maxOutputTokens.map(validPositiveBound) ?? true,
                    metadata.inputModalities.count <= 32,
                    metadata.outputModalities.count <= 32,
                    metadata.inputModalities.allSatisfy(validModality),
                    metadata.outputModalities.allSatisfy(validModality)
                else {
                    throw ProviderModelCatalogError.malformed
                }
                if let pricing = metadata.pricing {
                    guard
                        pricingEndpointsMatch(
                            pricing.baseURLs, providerID: provider.id, providerBaseURL: provider.baseURL)
                    else {
                        throw ProviderModelCatalogError.malformed
                    }
                }
            }
        }
    }

    private func pricingEndpointsMatch(_ values: [String], providerID: String, providerBaseURL: String) -> Bool {
        guard let expected = CanonicalAddress(providerBaseURL), !values.isEmpty else { return false }
        let endpoints = values.compactMap(CanonicalAddress.init)
        guard endpoints.count == values.count else { return false }
        if providerID == "deepseek" {
            return endpoints.allSatisfy {
                $0.scheme == expected.scheme && $0.host == expected.host && $0.port == expected.port
                    && ($0.path == expected.path || $0.path == expected.path + "/v1")
            }
        }
        return endpoints.count == 1 && endpoints[0] == expected
    }
}

private struct CanonicalAddress: Hashable {
    let scheme: String
    let host: String
    let port: Int?
    let path: String

    func withPath(_ path: String) -> CanonicalAddress {
        CanonicalAddress(scheme: scheme, host: host, port: port, path: path)
    }

    private init(scheme: String, host: String, port: Int?, path: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }

    init?(_ rawValue: String) {
        guard let components = URLComponents(string: rawValue),
            let host = components.host?.lowercased(), !host.isEmpty,
            let scheme = components.scheme?.lowercased(), !scheme.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            scheme == "https" || scheme == "http"
        else { return nil }
        guard components.percentEncodedPath == components.path,
            !components.path.hasSuffix("//")
        else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = components.port == 443 ? nil : components.port
        var path = components.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        self.path = path == "/" ? "" : path
    }
}

private func validToken(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 300 else { return false }
    return !value.unicodeScalars.contains {
        CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
    }
}

private func validDisplayText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.count <= maximum
        && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
}

private func validOptionalDisplayText(_ value: String?) -> Bool {
    value.map { validDisplayText($0, maximum: 300) } ?? true
}

private func validHTTPSURL(_ value: String) -> Bool {
    guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
        components.host?.isEmpty == false, components.user == nil, components.password == nil,
        components.query == nil, components.fragment == nil
    else { return false }
    return true
}

private func validPositiveBound(_ value: Int) -> Bool { value > 0 && value <= 10_000_000 }
private func validModality(_ value: String) -> Bool { validDisplayText(value, maximum: 32) }
