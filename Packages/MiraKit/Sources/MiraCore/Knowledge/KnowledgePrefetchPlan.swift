import Foundation

/// Identifies ordinary questions that are likely to depend on an imported
/// local source. The host may use this as a cheap gate before local search.
/// It does not authorize disclosure; the KnowledgeStore still enforces scope,
/// workspace policy, and the selected connection.
public enum KnowledgePrefetchPlan {
    private struct Lexicon: Decodable {
        let sourceCues: [String]
        let referenceCues: [String]
        let queryStopWords: [String]
    }

    private static let lexicon: Lexicon? = {
        guard let url = Bundle.module.url(forResource: "KnowledgePrefetchLexicon", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Lexicon.self, from: data)
    }()

    public static func shouldPrefetch(query: String) -> Bool {
        let normalized = normalize(query)
        guard !normalized.isEmpty, let lexicon else { return false }
        return lexicon.sourceCues.contains { containsSignal($0, in: normalized) } &&
            lexicon.referenceCues.contains { containsSignal($0, in: normalized) }
    }

    /// Removes reviewed source/reference framing and common function words so
    /// the SQL search receives the user's content terms. Knowledge search uses
    /// an AND query, so sending the whole natural-language question would miss
    /// nearly every source that does not repeat the question's wording.
    public static func sourceQuery(for query: String) -> String {
        let normalized = normalize(query)
        guard let lexicon else { return normalized }
        var cleaned = normalized
        let signals = (lexicon.sourceCues + lexicon.referenceCues + lexicon.queryStopWords)
            .map(normalize)
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for signal in signals {
            cleaned = removingSignal(signal, from: cleaned)
        }
        let terms = cleaned
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation || $0.isNewline })
            .prefix(8)
            .map(String.init)
        if !terms.isEmpty { return terms.joined(separator: " ") }
        // A source-oriented question can contain only framing (for example,
        // "according to my notes, what does this say?"). Keep one explicit
        // source cue as a bounded fallback instead of issuing an empty query.
        return lexicon.sourceCues.first(where: { containsSignal($0, in: normalized) }).map(normalize) ?? normalized
    }

    private static func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func containsSignal(_ rawSignal: String, in normalizedText: String) -> Bool {
        let signal = normalize(rawSignal)
        guard !signal.isEmpty else { return false }
        let latinSignal = signal.unicodeScalars.contains {
            $0.value < 128 && CharacterSet.alphanumerics.contains($0)
        }
        guard latinSignal else { return normalizedText.contains(signal) }
        var start = normalizedText.startIndex
        while start < normalizedText.endIndex,
              let match = normalizedText.range(of: signal, range: start..<normalizedText.endIndex) {
            let before = match.lowerBound > normalizedText.startIndex
                ? normalizedText[normalizedText.index(before: match.lowerBound)] : nil
            let after = match.upperBound < normalizedText.endIndex
                ? normalizedText[match.upperBound] : nil
            let beforeWord = before.map { $0.unicodeScalars.count == 1 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } } ?? false
            let afterWord = after.map { $0.unicodeScalars.count == 1 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } } ?? false
            if !beforeWord && !afterWord { return true }
            start = match.upperBound
        }
        return false
    }

    private static func removingSignal(_ signal: String, from text: String) -> String {
        var text = text
        let latinSignal = signal.unicodeScalars.contains {
            $0.value < 128 && CharacterSet.alphanumerics.contains($0)
        }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let match = text.range(of: signal, range: start..<text.endIndex) {
            let before = match.lowerBound > text.startIndex ? text[text.index(before: match.lowerBound)] : nil
            let after = match.upperBound < text.endIndex ? text[match.upperBound] : nil
            let beforeWord = before.map { $0.unicodeScalars.count == 1 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } } ?? false
            let afterWord = after.map { $0.unicodeScalars.count == 1 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } } ?? false
            if !latinSignal || (!beforeWord && !afterWord) { ranges.append(match) }
            start = match.upperBound
        }
        for range in ranges.reversed() { text.replaceSubrange(range, with: " ") }
        return text
    }
}
