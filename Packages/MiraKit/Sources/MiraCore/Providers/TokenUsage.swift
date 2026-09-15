import Foundation

public enum InputTokenBasis: String, Codable, Sendable { case includesCache, excludesCache }

/// Counters are cumulative within one call. A missing counter is never zero.
/// Reasoning is a subset of output; cache counters are subsets of inclusive input.
public struct TokenUsage: Codable, Sendable, Equatable {
    /// Up to twenty decisions, including protocols with exclusive cache counts.
    public static let maximumAggregateTokens = 6_000_000_000
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?
    public var inputTokenBasis: InputTokenBasis

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil,
                cacheWriteTokens: Int? = nil, reasoningTokens: Int? = nil, inputTokenBasis: InputTokenBasis = .includesCache) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens; self.inputTokenBasis = inputTokenBasis
    }

    public func validate(maximumTokens: Int = 100_000_000) throws {
        guard [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens]
            .allSatisfy({ $0.map { (0...min(Self.maximumAggregateTokens, max(0, maximumTokens))).contains($0) } ?? true }),
              reasoningTokens.map({ value in outputTokens.map { value <= $0 } ?? true }) ?? true else {
            throw MiraError(.malformedStream, "Service returned invalid usage.")
        }
        if inputTokenBasis == .includesCache, let inputTokens,
           (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0) > inputTokens {
            throw MiraError(.malformedStream, "Service returned invalid usage.")
        }
    }

    public var totalInputTokens: Int? {
        guard (try? validate(maximumTokens: Self.maximumAggregateTokens)) != nil, let inputTokens else { return nil }
        if inputTokenBasis == .includesCache { return inputTokens }
        guard let cacheReadTokens, let cacheWriteTokens else { return nil }
        return inputTokens + cacheReadTokens + cacheWriteTokens
    }

    /// Only for distinct calls, never for consecutive streaming usage events.
    public func adding(_ other: TokenUsage) -> TokenUsage {
        func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard let lhs, let rhs else { return nil }
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? nil : value
        }
        let sameBasis = inputTokenBasis == other.inputTokenBasis
        return .init(inputTokens: sum(sameBasis ? inputTokens : totalInputTokens,
                                      sameBasis ? other.inputTokens : other.totalInputTokens),
                     outputTokens: sum(outputTokens, other.outputTokens),
                     cacheReadTokens: sum(cacheReadTokens, other.cacheReadTokens),
                     cacheWriteTokens: sum(cacheWriteTokens, other.cacheWriteTokens),
                     reasoningTokens: sum(reasoningTokens, other.reasoningTokens),
                     inputTokenBasis: sameBasis ? inputTokenBasis : .includesCache)
    }
}
