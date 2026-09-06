import Foundation
import Testing
import MiraCore

struct CostPresentationTests {
    private var resources: Bundle { Bundle(for: CostLocalizationMarker.self) }
    @Test func costFormattingUsesDisplayLocaleAndPreservesSmallCharges() {
        let amount = Decimal(string: "0.00248")!
        #expect(CostPresentation.amount(amount, locale: Locale(identifier: "en_US")).contains("0.00248"))
        #expect(CostPresentation.amount(amount, locale: Locale(identifier: "zh_CN")).contains("0.00248"))
        let tiny = Decimal(1) / 1_000_000_000
        let english = CostPresentation.amount(tiny, locale: Locale(identifier: "en_US"), bundle: resources)
        let chinese = CostPresentation.amount(tiny, locale: Locale(identifier: "zh_CN"), bundle: resources)
        #expect(english.hasPrefix("Less than "))
        #expect(chinese != english)
        #expect(chinese.contains("0.00000001"))
    }

    @Test func everyUnknownCostReasonHasBothTranslations() {
        let reasons: [CostUnavailableReason] = [.missingPricing, .endpointMismatch, .missingUsage, .unsupportedCacheWrite, .inputLimitExceeded, .invalidUsage, .incompleteCall]
        for reason in reasons {
            let key = CostPresentation.reasonKey(reason)
            #expect(L10n.string(key, locale: Locale(identifier: "en"), bundle: resources) == key)
            #expect(L10n.string(key, locale: Locale(identifier: "zh_CN"), bundle: resources) != key)
        }
    }
}

private final class CostLocalizationMarker: NSObject {}
