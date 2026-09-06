import Foundation
import MiraCore

/// The checked-in, advisory provider/model catalog. It is loaded from the
/// package resource and never performs network access.
public struct ProviderModelCatalog: Sendable {
    public let providers: [CatalogProvider]

    public static let bundled: ProviderModelCatalog = {
        guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? ProviderModelCatalog(data: data) else {
            fatalError("The bundled model catalog is missing or malformed.")
        }
        return catalog
    }()

    /// Decodes a catalog snapshot for deterministic tests and build tooling.
    public init(data: Data) throws {
        do {
            let document = try JSONDecoder().decode(CatalogDocument.self, from: data)
            try document.validate()
            self.providers = document.providers.map(CatalogProvider.init)
        } catch let error as ProviderModelCatalogError {
            throw error
        } catch {
            throw ProviderModelCatalogError.malformed
        }
    }

    public func matchingProvider(for connection: ProviderConnection) -> CatalogProvider? {
        providers.first { provider in
            guard provider.providerKind == connection.providerKind,
                  let connectionAddress = CanonicalAddress(connection.baseURL),
                  let providerAddress = CanonicalAddress(provider.baseURL) else { return false }
            if provider.id == "deepseek" {
                guard connectionAddress.scheme == providerAddress.scheme,
                      connectionAddress.host == providerAddress.host,
                      connectionAddress.port == providerAddress.port else { return false }
                return connectionAddress.path == providerAddress.path ||
                    connectionAddress.path == providerAddress.path + "/v1"
            }
            return connectionAddress == providerAddress
        }
    }

    public func models(for connection: ProviderConnection) -> [CatalogModel] {
        matchingProvider(for: connection)?.models ?? []
    }

    public func model(for connection: ProviderConnection, modelID: String) -> CatalogModel? {
        matchingProvider(for: connection)?.models.first { $0.id == modelID }
    }
}

public struct CatalogProvider: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let documentationURL: String
    public let providerKind: ProviderKind
    public let models: [CatalogModel]

    fileprivate init(_ value: CatalogDocument.Provider) {
        id = value.id
        name = value.name
        baseURL = value.baseURL
        documentationURL = value.documentationURL
        providerKind = value.providerKind
        models = value.models.map(CatalogModel.init)
    }
}

public struct CatalogModel: Identifiable, Sendable {
    public let id: String
    public let metadata: ModelCatalogMetadata
    public let suggestedProtocolMode: ModelProtocolMode

    fileprivate init(_ value: CatalogDocument.Model) {
        id = value.metadata.modelID
        metadata = value.metadata
        suggestedProtocolMode = value.suggestedProtocolMode
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
        let providerKind: ProviderKind
        let models: [Model]

        enum CodingKeys: String, CodingKey {
            case id, name, baseURL, documentationURL, providerKind, models
        }
    }

    struct Model: Decodable {
        let metadata: ModelCatalogMetadata
        let suggestedProtocolMode: ModelProtocolMode

        enum CodingKeys: String, CodingKey { case metadata, suggestedProtocolMode }
    }

    func validate() throws {
        guard !providers.isEmpty, providers.count <= 32 else { throw ProviderModelCatalogError.malformed }
        var providerIDs = Set<String>()
        for provider in providers {
            guard validToken(provider.id), providerIDs.insert(provider.id).inserted,
                  validDisplayText(provider.name, maximum: 100),
                  validHTTPSURL(provider.baseURL), CanonicalAddress(provider.baseURL) != nil,
                  validHTTPSURL(provider.documentationURL),
                  provider.models.count <= 2_000 else { throw ProviderModelCatalogError.malformed }
            var modelIDs = Set<String>()
            for model in provider.models {
                let metadata = model.metadata
                guard metadata.providerID == provider.id,
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
                      metadata.outputModalities.allSatisfy(validModality) else {
                    throw ProviderModelCatalogError.malformed
                }
            }
        }
    }
}

private struct CanonicalAddress: Equatable {
    let scheme: String
    let host: String
    let port: Int?
    let path: String

    init?(_ rawValue: String) {
        guard let components = URLComponents(string: rawValue),
              let host = components.host?.lowercased(), !host.isEmpty,
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || scheme == "http" else { return nil }
        // Matching is deliberately based on the parsed path. Reject encoded
        // separators so a catalog or connection cannot bypass exact-path
        // matching through percent-decoding differences.
        guard components.percentEncodedPath == components.path,
              !components.path.hasSuffix("//") else { return nil }
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
    !value.isEmpty && value.count <= maximum &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
}

private func validOptionalDisplayText(_ value: String?) -> Bool {
    value.map { validDisplayText($0, maximum: 300) } ?? true
}

private func validHTTPSURL(_ value: String) -> Bool {
    guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
          components.host?.isEmpty == false, components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil else { return false }
    return true
}

private func validPositiveBound(_ value: Int) -> Bool { value > 0 && value <= 10_000_000 }
private func validModality(_ value: String) -> Bool { validDisplayText(value, maximum: 32) }
