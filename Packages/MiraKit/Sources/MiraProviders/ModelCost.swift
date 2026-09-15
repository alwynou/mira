import Foundation
import MiraCore

public enum CostUnavailableReason: String, Sendable {
    case missingPricing, endpointMismatch, missingUsage, unsupportedCacheWrite, inputLimitExceeded, invalidUsage,
        incompleteCall
}

public enum ModelCostEstimate: Sendable, Equatable {
    case available(Decimal)
    case unavailable(CostUnavailableReason)

    public static func estimate(usage: TokenUsage, route: AgentModelRoute, isComplete: Bool = true) -> Self {
        guard isComplete else { return .unavailable(.incompleteCall) }
        guard (try? route.validate()) != nil,
            let configuration = try? SessionCodec.decode(
                HTTPModelConfiguration.self,
                from: SessionCodec.encode(route.configuration)),
            (try? configuration.jsonValue()) == route.configuration,
            let snapshot = configuration.pricing,
            snapshot.modelID == route.modelID,
            (try? snapshot.validate()) != nil,
            let endpoint = try? configuration.validatedEndpoint()
        else { return .unavailable(.missingPricing) }
        guard snapshot.pricing.matches(endpoint: endpoint, configuration: configuration) else {
            return .unavailable(.endpointMismatch)
        }
        guard (try? usage.validate()) != nil else { return .unavailable(.invalidUsage) }
        guard let input = usage.inputTokens, let output = usage.outputTokens else { return .unavailable(.missingUsage) }
        // Cache writes may have multiple TTL rates. Do not apply a flat rate
        // without a verified TTL breakdown. Missing writes on an exclusive
        // input protocol also leave the total unknown.
        if let writes = usage.cacheWriteTokens, writes > 0 { return .unavailable(.unsupportedCacheWrite) }
        if usage.inputTokenBasis == .excludesCache && usage.cacheWriteTokens == nil {
            return .unavailable(.missingUsage)
        }
        guard let totalInput = usage.totalInputTokens else { return .unavailable(.missingUsage) }
        if let maximum = snapshot.pricing.maxInputTokens, totalInput > maximum {
            return .unavailable(.inputLimitExceeded)
        }
        let uncached: Int
        let readCost: Decimal
        if let reads = usage.cacheReadTokens {
            guard reads == 0 || snapshot.pricing.cacheRead != nil else { return .unavailable(.missingPricing) }
            uncached = usage.inputTokenBasis == .includesCache ? input - reads : input
            readCost = Decimal(reads) * (snapshot.pricing.cacheRead ?? 0)
        } else {
            // Even a zero/free tariff needs complete reported usage. We do not
            // pretend an omitted cache counter means no cache was used.
            return .unavailable(.missingUsage)
        }
        return .available(
            (Decimal(uncached) * snapshot.pricing.input + readCost + Decimal(output) * snapshot.pricing.output)
                / 1_000_000)
    }
}

public struct ModelCallUsage: Identifiable, Sendable {
    public let id: UUID
    public let route: AgentModelRoute
    public let usage: TokenUsage
    public let createdAt: Date
    public let isComplete: Bool
    public init(id: UUID, route: AgentModelRoute, usage: TokenUsage, createdAt: Date, isComplete: Bool = true) {
        self.id = id
        self.route = route
        self.usage = usage
        self.createdAt = createdAt
        self.isComplete = isComplete
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
        self.init(estimates: calls.map(\.estimatedCost))
    }

    /// Summarizes the entire execution, never just the visible audit page.
    /// If privacy cleanup removed the frozen route, every recorded attempt remains unknown.
    public init(attempts: [SessionModelAttemptUsage], route: AgentModelRoute?) {
        self.init(estimates: attempts.map { attempt in
            guard let route else { return .unavailable(.missingPricing) }
            return .estimate(usage: attempt.usage, route: route, isComplete: attempt.isComplete)
        })
    }

    /// Summarizes durable memory extraction accounting. An attempt only
    /// represents a model call after dispatch; reservation and charge fields
    /// are accounting facts and are never used as a usage estimate.
    public init(extractionAttempts: [MemoryExtractionAttemptUsage]) {
        self.init(estimates: extractionAttempts.compactMap { attempt -> ModelCostEstimate? in
            guard attempt.dispatchedAt != nil else { return nil }
            guard attempt.state == .completed else { return .unavailable(.incompleteCall) }
            guard let usage = attempt.usage else { return .unavailable(.missingUsage) }
            guard let route = attempt.route else { return .unavailable(.missingPricing) }
            return .estimate(usage: usage, route: route)
        })
    }

    private init(estimates: [ModelCostEstimate]) {
        var amount: Decimal = 0
        var unknown = 0
        for estimate in estimates {
            switch estimate {
            case .available(let value): amount += value
            case .unavailable: unknown += 1
            }
        }
        knownUSD = amount
        unknownCalls = unknown
        callCount = estimates.count
    }
    public var totalUSD: Decimal? { unknownCalls == 0 ? knownUSD : nil }
}
