import Foundation
import Testing
import MiraCore

struct ModelCostTests {
    @Test func cachedInputAndThinkingAreNotChargedTwice() {
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 800, reasoningTokens: 150)
        #expect(ModelCostEstimate.estimate(usage: usage, route: route()) == .available(Decimal(string: "0.00248")!))
        let uncachedBasis = TokenUsage(inputTokens: 200, outputTokens: 200, cacheReadTokens: 800, cacheWriteTokens: 0, reasoningTokens: 150, inputTokenBasis: .excludesCache)
        #expect(uncachedBasis.totalInputTokens == 1_000)
        #expect(ModelCostEstimate.estimate(usage: uncachedBasis, route: route()) == .available(Decimal(string: "0.00248")!))
    }

    @Test func missingCacheAndUnsupportedWritesStayUnknown() {
        #expect(ModelCostEstimate.estimate(usage: .init(inputTokens: 100, outputTokens: 10), route: route()) == .unavailable(.missingUsage))
        #expect(ModelCostEstimate.estimate(usage: .init(inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 5), route: route()) == .unavailable(.unsupportedCacheWrite))
        let missingWrites = TokenUsage(inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, inputTokenBasis: .excludesCache)
        #expect(missingWrites.totalInputTokens == nil)
        #expect(ModelCostEstimate.estimate(usage: missingWrites, route: route()) == .unavailable(.missingUsage))
        let zero = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0)
        #expect(ModelCostEstimate.estimate(usage: zero, route: route()) == .available(0))
    }

    @Test func endpointModelAndPricingBoundsAreChecked() {
        let usage = TokenUsage(inputTokens: 101, outputTokens: 10, cacheReadTokens: 0)
        for url in ["https://proxy.example/v1", "https://api.example/other", "https://api.example/v1%2Fother", "https://api.example:444/v1"] {
            var changed = route(); changed.baseURL = url
            #expect(ModelCostEstimate.estimate(usage: usage, route: changed) == .unavailable(.endpointMismatch))
        }
        var wrongID = route(); wrongID.modelID = "another-model"
        #expect(ModelCostEstimate.estimate(usage: usage, route: wrongID) == .unavailable(.missingPricing))
        #expect(ModelCostEstimate.estimate(usage: usage, route: route(maxInput: 100)) == .unavailable(.inputLimitExceeded))
        var noPrice = route(); noPrice.catalogMetadata = nil
        #expect(ModelCostEstimate.estimate(usage: usage, route: noPrice) == .unavailable(.missingPricing))
    }

    @Test func partialCallTotalCannotMasqueradeAsCompleteAndHistoryIsFrozen() throws {
        let original = route()
        let bytes = try JSONEncoder().encode(original)
        let changed = route(inputRate: 20)
        let frozen = try JSONDecoder().decode(ResolvedModelRouteSnapshot.self, from: bytes)
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 800)
        #expect(ModelCostEstimate.estimate(usage: usage, route: frozen) != ModelCostEstimate.estimate(usage: usage, route: changed))
        let call = ModelCallUsage(id: UUID(), route: frozen, usage: usage, createdAt: .now)
        let missing = ModelCallUsage(id: UUID(), route: changed, usage: .init(), createdAt: .now)
        let summary = ModelCostSummary(calls: [call, missing])
        #expect(summary.knownUSD == Decimal(string: "0.00248")!)
        #expect(summary.unknownCalls == 1)
        #expect(summary.totalUSD == nil)
        #expect(ModelCostSummary(calls: [call, call]).totalUSD == Decimal(string: "0.00496")!)
        let interrupted = ModelCallUsage(id: UUID(), route: frozen, usage: usage, createdAt: .now, isComplete: false)
        #expect(interrupted.estimatedCost == .unavailable(.incompleteCall))
        #expect(ModelCostSummary(calls: [call, interrupted]).totalUSD == nil)
    }

    @Test func invalidUsageAndPricingAreRejected() throws {
        for usage in [TokenUsage(inputTokens: -1), .init(outputTokens: 100_000_001),
                      .init(inputTokens: 10, cacheReadTokens: 11), .init(outputTokens: 5, reasoningTokens: 6)] {
            #expect(throws: MiraError.self) { try usage.validate() }
        }
        for rate in [Decimal(-1), .nan, Decimal(1_000_001)] {
            #expect(throws: MiraError.self) { try ModelPricing(input: rate, output: 1, baseURLs: ["https://api.example/v1"]).validate() }
        }
        #expect(throws: MiraError.self) { try ModelPricing(input: 1, output: 1, baseURLs: ["https://user:secret@api.example/v1"]).validate() }
        try ModelPricing(input: 0, output: 0, baseURLs: ["https://api.example/v1"]).validate()
    }

    @Test func distinctCallsPreserveUnknownCountersAndInputBasis() throws {
        let first = TokenUsage(inputTokens: 100, outputTokens: 20, cacheReadTokens: 40, reasoningTokens: 5)
        let second = TokenUsage(inputTokens: 80, outputTokens: 10, cacheReadTokens: 30, reasoningTokens: 3)
        let total = first.adding(second)
        #expect(total.inputTokens == 180 && total.cacheReadTokens == 70 && total.reasoningTokens == 8)
        #expect(total.cacheWriteTokens == nil)
        #expect(first.adding(.init()).inputTokens == nil)
        let exclusive = TokenUsage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 20, cacheWriteTokens: 0, inputTokenBasis: .excludesCache)
        #expect(first.adding(exclusive).totalInputTokens == 130)
        let largeTotal = TokenUsage(inputTokens: 80_000_000).adding(.init(inputTokens: 80_000_000))
        try largeTotal.validate(maximumTokens: TokenUsage.maximumAggregateTokens)
        #expect(largeTotal.totalInputTokens == 160_000_000)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(exclusive))
        #expect(decoded == exclusive)
    }

    private func route(inputRate: Decimal = 2, maxInput: Int? = nil) -> ResolvedModelRouteSnapshot {
        let metadata = ModelCatalogMetadata(providerID: "fixture", modelID: "text-model", sourceURL: "https://catalog.example/data.json", sourceRevision: "fixture-v1", retrievedAt: "2026-09-06T00:00:00Z", task: .textGeneration,
                                            pricing: .init(input: inputRate, output: 10, cacheRead: Decimal(string: "0.1")!, baseURLs: ["https://api.example/v1"], maxInputTokens: maxInput))
        return .init(name: "Fixture", providerKind: .openAICompatible, baseURL: "https://api.example/v1", modelID: "text-model", credentialReference: "fixture-key", contextWindow: 4096, catalogMetadata: metadata)
    }
}
