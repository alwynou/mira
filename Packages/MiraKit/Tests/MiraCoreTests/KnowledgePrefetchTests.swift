import Foundation
import MiraCore
import Testing

@Suite("Knowledge prefetch planning")
struct KnowledgePrefetchTests {
    @Test(arguments: [
        "According to my notes, what does this say?",
        "What did I write in the Markdown document?",
        "根据我的笔记，里面提到了什么？", // i18n-fixture: source cue coverage.
        "这份资料里关于早餐写了什么？" // i18n-fixture: source cue coverage.
    ])
    func sourceQuestionsAreGatedForLocalSearch(_ query: String) {
        #expect(KnowledgePrefetchPlan.shouldPrefetch(query: query))
    }

    @Test(arguments: [
        "Please suggest a breakfast.",
        "My notes are important.",
        "What should I eat this morning?",
        "我的笔记很重要。" // i18n-fixture: reference cue must be present.
    ])
    func unrelatedOrUnderspecifiedQuestionsDoNotPrefetch(_ query: String) {
        #expect(!KnowledgePrefetchPlan.shouldPrefetch(query: query))
    }

    @Test func gateIsDeterministicAndDoesNotRewriteUserText() {
        let query = "According to my notes, what does the guide say about breakfast?"
        let first = KnowledgePrefetchPlan.shouldPrefetch(query: query)
        let second = KnowledgePrefetchPlan.shouldPrefetch(query: query)
        #expect(first == second)
        #expect(query == "According to my notes, what does the guide say about breakfast?")
    }
    @Test func sourceQueryKeepsContentTermsAndDropsQuestionFraming() {
        let query = "According to my Markdown notes, what does the guide say about breakfast?"
        #expect(KnowledgePrefetchPlan.sourceQuery(for: query) == "breakfast")
        #expect(!KnowledgePrefetchPlan.sourceQuery(for: "According to my notes, what does this say?").isEmpty)
        #expect(KnowledgePrefetchPlan.sourceQuery(for: "根据我的笔记，里面提到了早餐？") == "早餐") // i18n-fixture: source query cleanup.
        #expect(KnowledgePrefetchPlan.sourceQuery(for: "According to my notes, index onboarding anatomy?") == "index onboarding anatomy")
    }
}
