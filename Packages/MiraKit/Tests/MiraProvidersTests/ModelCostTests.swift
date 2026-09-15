import Foundation
import Testing

@testable import MiraCore
@testable import MiraProviders

struct ModelCostTests {
    @Test func cachedInputAndThinkingAreNotChargedTwice() throws {
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 800, reasoningTokens: 150)
        #expect(ModelCostEstimate.estimate(usage: usage, route: try route()) == .available(Decimal(string: "0.00248")!))
        let uncachedBasis = TokenUsage(
            inputTokens: 200, outputTokens: 200, cacheReadTokens: 800, cacheWriteTokens: 0, reasoningTokens: 150,
            inputTokenBasis: .excludesCache)
        #expect(uncachedBasis.totalInputTokens == 1_000)
        #expect(
            ModelCostEstimate.estimate(usage: uncachedBasis, route: try route())
                == .available(Decimal(string: "0.00248")!))
    }

    @Test func missingCacheAndUnsupportedWritesStayUnknown() throws {
        let priced = try route()
        #expect(
            ModelCostEstimate.estimate(usage: .init(inputTokens: 100, outputTokens: 10), route: priced)
                == .unavailable(.missingUsage))
        #expect(
            ModelCostEstimate.estimate(
                usage: .init(inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 5),
                route: priced) == .unavailable(.unsupportedCacheWrite))
        let missingWrites = TokenUsage(
            inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, inputTokenBasis: .excludesCache)
        #expect(missingWrites.totalInputTokens == nil)
        #expect(ModelCostEstimate.estimate(usage: missingWrites, route: priced) == .unavailable(.missingUsage))
        let zero = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0)
        #expect(ModelCostEstimate.estimate(usage: zero, route: priced) == .available(0))
    }

    @Test func endpointModelAndPricingBoundsAreChecked() throws {
        let usage = TokenUsage(inputTokens: 101, outputTokens: 10, cacheReadTokens: 0)
        for url in [
            "https://proxy.example/v1", "https://api.example/other", "https://api.example/v1%2Fother",
            "https://api.example:444/v1",
        ] {
            #expect(
                ModelCostEstimate.estimate(usage: usage, route: try route(baseURL: url))
                    == .unavailable(.endpointMismatch))
        }
        #expect(
            ModelCostEstimate.estimate(
                usage: usage,
                route: try route(baseURL: "https://API.EXAMPLE:443/v1", pricingBaseURL: "https://api.example/v1")
            ) == .available(Decimal(string: "0.000302")!))
        #expect(
            ModelCostEstimate.estimate(usage: usage, route: try route(modelID: "another-model"))
                == .unavailable(.missingPricing))
        #expect(
            ModelCostEstimate.estimate(usage: usage, route: try route(maxInput: 100))
                == .unavailable(.inputLimitExceeded))
        #expect(
            ModelCostEstimate.estimate(usage: usage, route: try route(hasPricing: false))
                == .unavailable(.missingPricing))
    }

    @Test func partialCallTotalCannotMasqueradeAsCompleteAndHistoryIsFrozen() throws {
        let original = try route()
        let bytes = try JSONEncoder().encode(original)
        let changed = try route(inputRate: 20)
        let frozen = try JSONDecoder().decode(AgentModelRoute.self, from: bytes)
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 800)
        #expect(
            ModelCostEstimate.estimate(usage: usage, route: frozen)
                != ModelCostEstimate.estimate(usage: usage, route: changed))
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

    @Test func executionSummaryKeepsEveryAttemptAndMissingFrozenPricesUnknown() throws {
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 800)
        let complete = SessionModelAttemptUsage(id: UUID(), startedAt: .now, usage: usage, isComplete: true)
        let incomplete = SessionModelAttemptUsage(id: UUID(), startedAt: .now, usage: usage, isComplete: false)
        let missing = SessionModelAttemptUsage(id: UUID(), startedAt: .now, usage: .init(), isComplete: true)
        let mixed = ModelCostSummary(attempts: [complete, incomplete, missing], route: try route())
        #expect(mixed.callCount == 3)
        #expect(mixed.knownUSD == Decimal(string: "0.00248")!)
        #expect(mixed.unknownCalls == 2 && mixed.totalUSD == nil)
        let purged = ModelCostSummary(attempts: [complete, incomplete, missing], route: nil)
        #expect(purged.callCount == 3 && purged.unknownCalls == 3)
        #expect(purged.knownUSD == 0 && purged.totalUSD == nil)
        let allKnown = ModelCostSummary(attempts: [complete, complete], route: try route())
        #expect(allKnown.totalUSD == Decimal(string: "0.00496")!)
        let local = ModelCostSummary(attempts: [], route: nil)
        #expect(local.callCount == 0 && local.unknownCalls == 0)
    }

    @Test func extractionPreDispatchFailuresAreNotModelCalls() throws {
        let attempts = [
            try extraction(state: .claimed),
            try extraction(state: .prepared, reservedTokens: 1_200),
            try extraction(state: .failed),
        ]
        let summary = ModelCostSummary(extractionAttempts: attempts)
        #expect(summary.callCount == 0)
        #expect(summary.unknownCalls == 0)
        #expect(summary.knownUSD == 0)
    }

    @Test func extractionMixKeepsCompletedSubtotalAndCountsDispatchedUnknown() throws {
        let completed = try extraction(state: .completed, route: try route())
        let failedBeforeDispatch = try extraction(state: .failed)
        let stillDispatched = try extraction(state: .dispatched, route: try route())
        let paused = try extraction(state: .paused, route: try route())
        let summary = ModelCostSummary(extractionAttempts: [completed, failedBeforeDispatch, stillDispatched, paused])
        #expect(summary.callCount == 3)
        #expect(summary.knownUSD == Decimal(string: "0.00248")!)
        #expect(summary.unknownCalls == 2)
        #expect(summary.totalUSD == nil)
    }

    @Test func extractionUsesEachAttemptFrozenRoute() throws {
        let first = try extraction(state: .completed, route: try route(inputRate: 2))
        let second = try extraction(state: .completed, route: try route(inputRate: 4))
        let summary = ModelCostSummary(extractionAttempts: [first, second])
        #expect(summary.callCount == 2)
        #expect(summary.unknownCalls == 0)
        #expect(summary.knownUSD == Decimal(string: "0.00536")!)
    }

    @Test func extractionPurgedRouteRemainsAccountedButUnknown() throws {
        let purged = try extraction(state: .completed, route: nil, bodyPurgedAt: .now)
        let summary = ModelCostSummary(extractionAttempts: [purged])
        #expect(summary.callCount == 1)
        #expect(summary.unknownCalls == 1)
        #expect(summary.knownUSD == 0)
        #expect(summary.totalUSD == nil)
    }

    @Test func extractionMissingUsageCounterDoesNotUseChargedTokens() throws {
        let missingCounter = try extraction(
            state: .completed,
            route: try route(),
            usage: TokenUsage(inputTokens: 100, outputTokens: 10),
            chargedTokens: 110)
        let summary = ModelCostSummary(extractionAttempts: [missingCounter])
        #expect(summary.callCount == 1)
        #expect(summary.unknownCalls == 1)
        #expect(summary.knownUSD == 0)
        #expect(summary.totalUSD == nil)
    }

    @Test func invalidUsageAndPricingAreRejected() throws {
        for usage in [
            TokenUsage(inputTokens: -1), .init(outputTokens: 100_000_001),
            .init(inputTokens: 10, cacheReadTokens: 11), .init(outputTokens: 5, reasoningTokens: 6),
        ] {
            #expect(throws: MiraError.self) { try usage.validate() }
        }
        for rate in [Decimal(-1), .nan, Decimal(1_000_001)] {
            #expect(throws: MiraError.self) {
                try ModelPricing(input: rate, output: 1, baseURLs: ["https://api.example/v1"]).validate()
            }
        }
        #expect(throws: MiraError.self) {
            try ModelPricing(input: 1, output: 1, baseURLs: ["https://user:secret@api.example/v1"]).validate()
        }
        try ModelPricing(input: 0, output: 0, baseURLs: ["https://api.example/v1"]).validate()
    }

    @Test func distinctCallsPreserveUnknownCountersAndInputBasis() throws {
        let first = TokenUsage(inputTokens: 100, outputTokens: 20, cacheReadTokens: 40, reasoningTokens: 5)
        let second = TokenUsage(inputTokens: 80, outputTokens: 10, cacheReadTokens: 30, reasoningTokens: 3)
        let total = first.adding(second)
        #expect(total.inputTokens == 180 && total.cacheReadTokens == 70 && total.reasoningTokens == 8)
        #expect(total.cacheWriteTokens == nil)
        #expect(first.adding(.init()).inputTokens == nil)
        let exclusive = TokenUsage(
            inputTokens: 10, outputTokens: 5, cacheReadTokens: 20, cacheWriteTokens: 0, inputTokenBasis: .excludesCache)
        #expect(first.adding(exclusive).totalInputTokens == 130)
        let largeTotal = TokenUsage(inputTokens: 80_000_000).adding(.init(inputTokens: 80_000_000))
        try largeTotal.validate(maximumTokens: TokenUsage.maximumAggregateTokens)
        #expect(largeTotal.totalInputTokens == 160_000_000)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(exclusive))
        #expect(decoded == exclusive)
    }

    private func route(
        inputRate: Decimal = 2, maxInput: Int? = nil, modelID: String = "text-model",
        pricingModelID: String = "text-model", baseURL: String = "https://api.example/v1",
        pricingBaseURL: String = "https://api.example/v1", hasPricing: Bool = true
    ) throws -> AgentModelRoute {
        let pricing = ModelPricing(
            input: inputRate, output: 10, cacheRead: Decimal(string: "0.1")!,
            baseURLs: [pricingBaseURL], maxInputTokens: maxInput)
        let snapshot =
            hasPricing
            ? HTTPModelPricingSnapshot(
                modelID: pricingModelID, sourceURL: "https://catalog.example/data.json",
                sourceRevision: "fixture-v1", retrievedAt: "2026-09-06T00:00:00Z", pricing: pricing) : nil
        let configuration = HTTPModelConfiguration(baseURL: baseURL, pricing: snapshot)
        return .init(
            id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, adapter: ProtocolFixture.openAI.identity,
            modelID: modelID, credential: .init(reference: "fixture-key", version: 1),
            contextWindow: 4_096, maximumOutputTokens: 1_024,
            capabilities: .init(streamsText: true, callsTools: false, producesThinking: false),
            configuration: try configuration.jsonValue())
    }

    private func extraction(
        state: MemoryExtractionAttemptState,
        route: AgentModelRoute? = nil,
        usage: TokenUsage? = TokenUsage(inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 800),
        reservedTokens: Int = 1_200,
        chargedTokens: Int? = nil,
        bodyPurgedAt: Date? = nil
    ) throws -> MemoryExtractionAttemptUsage {
        let isCompleted = state == .completed
        let isPreDispatch = state == .claimed || state == .prepared || state == .failed
        let dispatched = isPreDispatch
            ? nil : Date(timeIntervalSince1970: 10)
        let settled = state == .claimed || state == .prepared || state == .dispatched
            ? nil : Date(timeIntervalSince1970: 20)
        let effectiveReserved = state == .claimed || state == .failed ? 0 : reservedTokens
        let effectiveCharged = chargedTokens ?? (state == .completed ? 1_200 : (state == .paused ? effectiveReserved : 0))
        let effectiveRoute = try bodyPurgedAt == nil ? (route ?? self.route()) : nil
        let effectiveUsage = isCompleted ? usage : nil
        let value = MemoryExtractionAttemptUsage(
            id: UUID(), jobID: MemoryExtractionJobID(), ordinal: 1, state: state,
            startedAt: Date(timeIntervalSince1970: 1), dispatchedAt: dispatched, settledAt: settled,
            budgetDay: effectiveReserved > 0 ? Date(timeIntervalSince1970: 0) : nil,
            reservedTokens: effectiveReserved, chargedTokens: effectiveCharged, usage: effectiveUsage,
            route: effectiveRoute, bodyPurgedAt: bodyPurgedAt)
        try value.validate()
        return value
    }
}
