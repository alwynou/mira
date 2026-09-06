import Foundation

/// A bounded, local query expansion for ordinary memory association.
///
/// The planner emits only high-signal topic terms. It never rewrites user
/// content, calls a provider, or turns generic words such as "morning" into a
/// standalone search term. Data-layer search still applies all scope,
/// lifecycle, and disclosure filters before using these terms.
public struct MemoryRecallExpansion: Sendable, Equatable {
    public let aliasTerms: [String]
    public let matchedTopics: [String]

    public init(aliasTerms: [String] = [], matchedTopics: [String] = []) {
        self.aliasTerms = aliasTerms
        self.matchedTopics = matchedTopics
    }
}

public enum MemoryRecallPlanner {
    private struct Rule: Decodable {
        let id: String
        let directTriggers: [String]
        let contextCues: [String]
        let actionCues: [String]
        let aliases: [String]
    }

    private struct Lexicon: Decodable {
        let rules: [Rule]
    }

    // The reviewed resource is immutable for the lifetime of the process. Keep
    // decoding out of the hot path and avoid repeatedly touching the bundle.
    private static let lexicon: Lexicon? = {
        guard let url = Bundle.module.url(forResource: "MemoryRecallLexicon", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Lexicon.self, from: data)
    }()

    /// Expands a query using a small reviewed bilingual lexicon. The result is
    /// deterministic and capped so it cannot turn prefetch into a broad scan.
    public static func expand(query: String) -> MemoryRecallExpansion {
        let normalized = normalize(query)
        guard !normalized.isEmpty, let lexicon else {
            return .init()
        }

        var aliases: [String] = []
        var topics: [String] = []
        for rule in lexicon.rules {
            let direct = rule.directTriggers.contains { containsSignal($0, in: normalized) }
            let contextual = !rule.contextCues.isEmpty && !rule.actionCues.isEmpty &&
                rule.contextCues.contains { containsSignal($0, in: normalized) } &&
                rule.actionCues.contains { containsSignal($0, in: normalized) }
            guard direct || contextual else { continue }
            topics.append(rule.id)
            for alias in rule.aliases {
                let value = normalize(alias)
                guard !value.isEmpty, !aliases.contains(value) else { continue }
                aliases.append(value)
                if aliases.count == 8 { break }
            }
            if aliases.count == 8 { break }
        }
        return .init(aliasTerms: aliases, matchedTopics: topics)
    }

    private static func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Latin signals are phrases, so avoid matching them inside larger words
    /// (for example, "notes" in "noteworthy"). CJK signals remain substring
    /// matches because normal Chinese text does not delimit words with spaces.
    private static func containsSignal(_ rawSignal: String, in normalizedText: String) -> Bool {
        let signal = normalize(rawSignal)
        guard !signal.isEmpty else { return false }
        let latinSignal = signal.unicodeScalars.contains {
            $0.value < 128 && CharacterSet.alphanumerics.contains($0)
        }
        guard latinSignal else { return normalizedText.contains(signal) }

        var searchStart = normalizedText.startIndex
        while searchStart < normalizedText.endIndex,
              let match = normalizedText.range(of: signal, range: searchStart..<normalizedText.endIndex) {
            let before = match.lowerBound > normalizedText.startIndex
                ? normalizedText[normalizedText.index(before: match.lowerBound)] : nil
            let after = match.upperBound < normalizedText.endIndex
                ? normalizedText[match.upperBound] : nil
            if !isLatinWordCharacter(before) && !isLatinWordCharacter(after) { return true }
            searchStart = match.upperBound
        }
        return false
    }

    private static func isLatinWordCharacter(_ character: Character?) -> Bool {
        guard let character, let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
