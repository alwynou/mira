import Foundation
import MiraCore

/// Display-only curated official reference for DeepSeek's variable tariff.
/// The varying peak/off-peak rates must not become a flat cost estimate.
public struct ModelPublishedPricing: Sendable, Equatable {
    public let inputMinimum: Decimal
    public let inputMaximum: Decimal
    public let outputMinimum: Decimal
    public let outputMaximum: Decimal
    public let cacheReadMinimum: Decimal
    public let cacheReadMaximum: Decimal
    public let sourceURL: String
    public let checkedAt: String

    public init(
        inputMinimum: Decimal, inputMaximum: Decimal,
        outputMinimum: Decimal, outputMaximum: Decimal,
        cacheReadMinimum: Decimal, cacheReadMaximum: Decimal,
        sourceURL: String, checkedAt: String
    ) {
        self.inputMinimum = inputMinimum; self.inputMaximum = inputMaximum
        self.outputMinimum = outputMinimum; self.outputMaximum = outputMaximum
        self.cacheReadMinimum = cacheReadMinimum; self.cacheReadMaximum = cacheReadMaximum
        self.sourceURL = sourceURL; self.checkedAt = checkedAt
    }
}

/// Standard text-token rates in USD per million tokens. Provenance belongs to
/// the enclosing immutable HTTPModelPricingSnapshot frozen into each call's route.
public struct ModelPricing: Codable, Sendable, Equatable {
    public let input: Decimal
    public let output: Decimal
    public let cacheRead: Decimal?
    public let baseURLs: [String]
    public let maxInputTokens: Int?
    public let effectiveAt: String?

    public init(
        input: Decimal, output: Decimal, cacheRead: Decimal? = nil, baseURLs: [String],
        maxInputTokens: Int? = nil, effectiveAt: String? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.baseURLs = baseURLs
        self.maxInputTokens = maxInputTokens
        self.effectiveAt = effectiveAt
    }

    public func validate() throws {
        guard
            [Optional(input), Optional(output), cacheRead].allSatisfy({ rate in
                rate.map { !$0.isNaN && $0 >= 0 && $0 <= 1_000_000 } ?? true
            }), !baseURLs.isEmpty, baseURLs.count <= 4,
            maxInputTokens.map({ (1...10_000_000).contains($0) }) ?? true,
            effectiveAt.map({ !$0.isEmpty && $0.count <= 100 }) ?? true
        else {
            throw MiraError(.configuration, "The model pricing metadata is invalid.")
        }
        for baseURL in baseURLs {
            guard baseURL.utf8.count <= 2_048, URLComponents(string: baseURL)?.scheme == "https" else {
                throw MiraError(.configuration, "The model pricing metadata is invalid.")
            }
            _ = try HTTPModelConfiguration(baseURL: baseURL).validatedEndpoint()
        }
    }

    func matches(endpoint: URL, configuration: HTTPModelConfiguration) -> Bool {
        func normalized(_ url: URL) -> URLComponents? {
            guard var value = URLComponents(url: url, resolvingAgainstBaseURL: false),
                value.percentEncodedPath == value.path
            else { return nil }
            value.host = value.host?.lowercased()
            if value.port == 443 { value.port = nil }
            return value
        }
        guard let actual = normalized(endpoint) else { return false }
        return baseURLs.contains { baseURL in
            guard
                let expected = try? HTTPModelConfiguration(
                    baseURL: baseURL,
                    protocolID: configuration.protocolID,
                    dialectProfileID: configuration.dialectProfileID
                ).validatedEndpoint(), let candidate = normalized(expected)
            else { return false }
            return actual == candidate
        }
    }
}

/// Provider-owned price provenance. This value travels inside opaque route settings;
/// the core does not interpret a tariff, URL, currency or provider family.
public struct HTTPModelPricingSnapshot: Codable, Sendable, Equatable {
    public let modelID: String
    public let sourceURL: String
    public let sourceRevision: String
    public let retrievedAt: String
    public let pricing: ModelPricing

    public init(
        modelID: String, sourceURL: String, sourceRevision: String, retrievedAt: String,
        pricing: ModelPricing
    ) {
        self.modelID = modelID
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.retrievedAt = retrievedAt
        self.pricing = pricing
    }

    public init(catalog: CatalogModelMetadata) throws {
        try catalog.validate()
        guard catalog.task == .textGeneration, let pricing = catalog.pricing else {
            throw MiraError(.configuration, "The model pricing metadata is invalid.")
        }
        self.init(
            modelID: catalog.modelID, sourceURL: catalog.sourceURL,
            sourceRevision: catalog.sourceRevision, retrievedAt: catalog.retrievedAt, pricing: pricing)
        try validate()
    }

    public func validate() throws {
        try pricing.validate()
        for (value, bound) in [(modelID, 512), (sourceURL, 2_048), (sourceRevision, 300), (retrievedAt, 100)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                value.utf8.count <= bound
            else {
                throw MiraError(.configuration, "The model pricing metadata is invalid.")
            }
        }
    }

    static var schema: JSONValue {
        func string(_ maximum: Int) -> JSONValue {
            .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(Double(maximum))])
        }
        let rate: JSONValue = .object([
            "type": .string("number"), "minimum": .number(0), "maximum": .number(1_000_000),
        ])
        let tariff: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "input": rate, "output": rate, "cacheRead": rate,
                "baseURLs": .object([
                    "type": .string("array"), "minItems": .number(1),
                    "maxItems": .number(4), "items": string(2_048),
                ]),
                "maxInputTokens": .object([
                    "type": .string("integer"), "minimum": .number(1),
                    "maximum": .number(10_000_000),
                ]),
                "effectiveAt": string(100),
            ]),
            "required": .array([.string("input"), .string("output"), .string("baseURLs")]),
            "additionalProperties": .bool(false),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object([
                "modelID": string(512), "sourceURL": string(2_048), "sourceRevision": string(300),
                "retrievedAt": string(100), "pricing": tariff,
            ]),
            "required": .array(
                ["modelID", "sourceURL", "sourceRevision", "retrievedAt", "pricing"].map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }
}

public extension ProviderModelCatalog {
    /// Returns a display-only curated reference for the official DeepSeek tariff.
    /// Its varying peak/off-peak rates must not become a flat cost estimate.
    func publishedPricing(
        for connection: AgentConfiguredConnection, modelID: String, endpointID: String? = nil
    ) -> ModelPublishedPricing? {
        guard matchingProvider(for: connection, endpointID: endpointID)?.id == "deepseek" else { return nil }
        switch modelID {
        case "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp":
            return .init(
                inputMinimum: Decimal(string: "0.15")!, inputMaximum: Decimal(string: "0.30")!,
                outputMinimum: Decimal(string: "0.60")!, outputMaximum: Decimal(string: "1.20")!,
                cacheReadMinimum: Decimal(string: "0.003")!, cacheReadMaximum: Decimal(string: "0.006")!,
                sourceURL: "https://api-docs.deepseek.com/quick_start/pricing/",
                checkedAt: "2026-09-14")
        case "deepseek-v4-pro":
            return .init(
                inputMinimum: Decimal(string: "0.66")!, inputMaximum: Decimal(string: "1.32")!,
                outputMinimum: Decimal(string: "1.98")!, outputMaximum: Decimal(string: "3.96")!,
                cacheReadMinimum: Decimal(string: "0.022")!, cacheReadMaximum: Decimal(string: "0.044")!,
                sourceURL: "https://api-docs.deepseek.com/quick_start/pricing/",
                checkedAt: "2026-09-14")
        default:
            return nil
        }
    }
}
