import Foundation

/// Standard text-token rates in USD per million tokens. Provenance belongs to
/// the enclosing immutable ModelCatalogMetadata copied into each call's route.
public struct ModelPricing: Codable, Sendable, Equatable {
    public let input: Decimal
    public let output: Decimal
    public let cacheRead: Decimal?
    public let baseURLs: [String]
    public let maxInputTokens: Int?
    public let effectiveAt: String?

    public init(input: Decimal, output: Decimal, cacheRead: Decimal? = nil, baseURLs: [String],
                maxInputTokens: Int? = nil, effectiveAt: String? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.baseURLs = baseURLs; self.maxInputTokens = maxInputTokens; self.effectiveAt = effectiveAt
    }

    public func validate() throws {
        guard [Optional(input), Optional(output), cacheRead].allSatisfy({ rate in
            rate.map { !$0.isNaN && $0 >= 0 && $0 <= 1_000_000 } ?? true
        }), !baseURLs.isEmpty, baseURLs.count <= 4,
              maxInputTokens.map({ (1...10_000_000).contains($0) }) ?? true,
              effectiveAt.map({ !$0.isEmpty && $0.count <= 100 }) ?? true else {
            throw MiraError(.configuration, "The model pricing metadata is invalid.")
        }
        for baseURL in baseURLs {
            guard URLComponents(string: baseURL)?.scheme == "https" else {
                throw MiraError(.configuration, "The model pricing metadata is invalid.")
            }
            _ = try ProviderEndpoint.resolve(kind: .openAICompatible, baseURL: baseURL, allowsLoopbackHTTP: false)
        }
    }

    func matches(_ route: ResolvedModelRouteSnapshot) -> Bool {
        guard let actual = try? route.validatedEndpoint() else { return false }
        return baseURLs.contains { baseURL in
            guard let expected = try? ProviderEndpoint.resolve(kind: route.providerKind, baseURL: baseURL, allowsLoopbackHTTP: false) else { return false }
            func normalized(_ url: URL) -> URLComponents? {
                guard var value = URLComponents(url: url, resolvingAgainstBaseURL: false), value.percentEncodedPath == value.path else { return nil }
                value.host = value.host?.lowercased()
                if value.port == 443 { value.port = nil }
                return value
            }
            guard let left = normalized(actual), let right = normalized(expected) else { return false }
            return left == right
        }
    }
}

public enum CostUnavailableReason: String, Sendable {
    case missingPricing, endpointMismatch, missingUsage, unsupportedCacheWrite, inputLimitExceeded, invalidUsage, incompleteCall
}

public enum ModelCostEstimate: Sendable, Equatable {
    case available(Decimal)
    case unavailable(CostUnavailableReason)

    public static func estimate(usage: TokenUsage, route: ResolvedModelRouteSnapshot, isComplete: Bool = true) -> Self {
        guard isComplete else { return .unavailable(.incompleteCall) }
        guard let metadata = route.catalogMetadata, metadata.modelID == route.modelID,
              metadata.task == .textGeneration, let price = metadata.pricing,
              (try? price.validate()) != nil else { return .unavailable(.missingPricing) }
        guard price.matches(route) else { return .unavailable(.endpointMismatch) }
        guard (try? usage.validate()) != nil else { return .unavailable(.invalidUsage) }
        guard let input = usage.inputTokens, let output = usage.outputTokens else { return .unavailable(.missingUsage) }
        // Cache writes may have multiple TTL rates. Do not apply a flat rate
        // without a verified TTL breakdown. Missing writes on an exclusive
        // input protocol also leave the total unknown.
        if let writes = usage.cacheWriteTokens, writes > 0 { return .unavailable(.unsupportedCacheWrite) }
        if usage.inputTokenBasis == .excludesCache && usage.cacheWriteTokens == nil { return .unavailable(.missingUsage) }
        guard let totalInput = usage.totalInputTokens else { return .unavailable(.missingUsage) }
        if let maximum = price.maxInputTokens, totalInput > maximum { return .unavailable(.inputLimitExceeded) }
        let uncached: Int
        let readCost: Decimal
        if let reads = usage.cacheReadTokens {
            guard reads == 0 || price.cacheRead != nil else { return .unavailable(.missingPricing) }
            uncached = usage.inputTokenBasis == .includesCache ? input - reads : input
            readCost = Decimal(reads) * (price.cacheRead ?? 0)
        } else {
            // Even a zero/free tariff needs complete reported usage. We do not
            // pretend an omitted cache counter means no cache was used.
            return .unavailable(.missingUsage)
        }
        return .available((Decimal(uncached) * price.input + readCost + Decimal(output) * price.output) / 1_000_000)
    }
}

public struct ModelCallUsage: Identifiable, Sendable {
    public let id: UUID
    public let route: ResolvedModelRouteSnapshot
    public let usage: TokenUsage
    public let createdAt: Date
    public let isComplete: Bool
    public init(id: UUID, route: ResolvedModelRouteSnapshot, usage: TokenUsage, createdAt: Date, isComplete: Bool = true) {
        self.id = id; self.route = route; self.usage = usage; self.createdAt = createdAt; self.isComplete = isComplete
    }
    public var estimatedCost: ModelCostEstimate { .estimate(usage: usage, route: route, isComplete: isComplete) }
}

/// A total is available only if every actual call is priced. Unknown calls
/// remain visible rather than silently disappearing from an apparent total.
public struct ModelCostSummary: Sendable {
    public let knownUSD: Decimal
    public let unknownCalls: Int
    public let callCount: Int
    public init(calls: [ModelCallUsage]) {
        var amount: Decimal = 0, unknown = 0
        for call in calls {
            switch call.estimatedCost {
            case .available(let value): amount += value
            case .unavailable: unknown += 1
            }
        }
        knownUSD = amount; unknownCalls = unknown; callCount = calls.count
    }
    public var totalUSD: Decimal? { unknownCalls == 0 ? knownUSD : nil }
}
