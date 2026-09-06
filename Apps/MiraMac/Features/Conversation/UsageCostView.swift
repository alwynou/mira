import SwiftUI
import MiraCore

struct UsageCostView: View {
    @Environment(\.locale) private var locale
    let usage: TokenUsage
    let route: ResolvedModelRouteSnapshot
    var isComplete = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Input tokens", value: counter(usage.totalInputTokens))
            if usage.inputTokenBasis == .excludesCache {
                LabeledContent("Uncached input tokens", value: counter(usage.inputTokens))
            }
            LabeledContent("Output tokens", value: counter(usage.outputTokens))
            LabeledContent("Cache read tokens", value: counter(usage.cacheReadTokens))
            LabeledContent("Cache write tokens", value: counter(usage.cacheWriteTokens))
            LabeledContent("Thinking tokens (included in output)", value: counter(usage.reasoningTokens))
            switch ModelCostEstimate.estimate(usage: usage, route: route, isComplete: isComplete) {
            case .available(let amount):
                LabeledContent("Estimated cost (USD)", value: CostPresentation.amount(amount, locale: locale))
            case .unavailable(let reason):
                LabeledContent("Estimated cost (USD)", value: L10n.string("Unknown", locale: locale))
                Text(L10n.string(CostPresentation.reasonKey(reason), locale: locale))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.caption)
    }

    private func counter(_ value: Int?) -> String {
        value.map { $0.formatted(.number.locale(locale)) } ?? L10n.string("Service did not provide this", locale: locale)
    }
}

struct CostSummaryView: View {
    @Environment(\.locale) private var locale
    let calls: [ModelCallUsage]
    let isBackground: Bool

    private var summary: ModelCostSummary { .init(calls: calls) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                if calls.isEmpty {
                    Text("No recorded calls")
                } else if let amount = summary.totalUSD {
                    Text(CostPresentation.amount(amount, locale: locale))
                } else {
                    Text("Unknown")
                }
            } label: {
                Text(LocalizedStringKey(isBackground ? "Background estimated cost (USD)" : "Foreground estimated cost (USD)"))
            }
            if summary.unknownCalls > 0 {
                Text(L10n.format("Known subtotal: %@ · Calls with unknown cost: %lld", locale: locale,
                                 CostPresentation.amount(summary.knownUSD, locale: locale), Int64(summary.unknownCalls)))
            }
            Text("Estimates use the catalog frozen for each call. They are not the provider's bill.")
        }.font(.caption).foregroundStyle(.secondary)
    }
}

enum CostPresentation {
    static func amount(_ value: Decimal, locale: Locale, bundle: Bundle = .main) -> String {
        let minimum = Decimal(1) / 100_000_000
        let style = Decimal.FormatStyle.Currency(code: "USD").precision(.fractionLength(2...8)).locale(locale)
        if value > 0 && value < minimum {
            return L10n.format("Less than %@", locale: locale, bundle: bundle, minimum.formatted(style))
        }
        return value.formatted(style)
    }

    static func reasonKey(_ reason: CostUnavailableReason) -> String {
        switch reason {
        case .missingPricing: "No supported text pricing is saved for this model."
        case .endpointMismatch: "Catalog pricing does not apply to this endpoint."
        case .missingUsage: "The service did not report all usage needed for an estimate."
        case .unsupportedCacheWrite: "Cache write pricing requires a supported lifetime breakdown."
        case .inputLimitExceeded: "This call exceeds the catalog pricing range."
        case .invalidUsage: "The service returned inconsistent usage."
        case .incompleteCall: "This call has no confirmed final usage; partial counters are shown."
        }
    }
}
