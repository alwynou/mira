import Foundation
import MiraCore

enum MemoryContinuityMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case explicitSave
}

struct MemoryContinuityScenario: Codable, Sendable {
    let id: String
    let language: String
    let input: String
    let followUp: String
    let mode: MemoryContinuityMode
    let requiresCitation: Bool

    init(id: String, language: String, input: String, followUp: String,
         mode: MemoryContinuityMode, requiresCitation: Bool = false) {
        self.id = id
        self.language = language
        self.input = input
        self.followUp = followUp
        self.mode = mode
        self.requiresCitation = requiresCitation
    }
}

struct MemoryContinuityCorpus: Codable {
    let version: Int
    let scenarios: [MemoryContinuityScenario]

    func validate() throws {
        guard version == 1 else {
            throw MemoryContinuityCorpusError.invalidVersion(version)
        }

        let expectedLanguages = Set(["en", "zh-CN"])
        let expectedModes = Set(MemoryContinuityMode.allCases)
        guard scenarios.count == expectedLanguages.count * expectedModes.count else {
            throw MemoryContinuityCorpusError.invalidScenarioCount(scenarios.count)
        }

        var ids = Set<String>()
        var languageModes = Set<String>()
        for scenario in scenarios {
            guard !scenario.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryContinuityCorpusError.emptyScenarioID
            }
            guard ids.insert(scenario.id).inserted else {
                throw MemoryContinuityCorpusError.duplicateScenarioID(scenario.id)
            }
            guard expectedLanguages.contains(scenario.language) else {
                throw MemoryContinuityCorpusError.unknownLanguage(scenario.language)
            }
            guard !scenario.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryContinuityCorpusError.emptyInput(scenario.id)
            }
            guard !scenario.followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryContinuityCorpusError.emptyFollowUp(scenario.id)
            }
            let key = "\(scenario.language):\(scenario.mode.rawValue)"
            guard languageModes.insert(key).inserted else {
                throw MemoryContinuityCorpusError.duplicateLanguageMode(key)
            }
        }

        let expectedPairs = Set(expectedLanguages.flatMap { language in
            expectedModes.map { "\(language):\($0.rawValue)" }
        })
        guard languageModes == expectedPairs else {
            throw MemoryContinuityCorpusError.missingLanguageMode(expectedPairs.subtracting(languageModes).sorted())
        }
    }
}

enum MemoryContinuityCorpusError: Error, Equatable, CustomStringConvertible {
    case invalidVersion(Int)
    case invalidScenarioCount(Int)
    case emptyScenarioID
    case duplicateScenarioID(String)
    case unknownLanguage(String)
    case emptyInput(String)
    case emptyFollowUp(String)
    case duplicateLanguageMode(String)
    case missingLanguageMode([String])

    var description: String {
        switch self {
        case .invalidVersion(let value): "Unsupported continuity corpus version \(value)."
        case .invalidScenarioCount(let value): "Continuity corpus must contain four scenarios; found \(value)."
        case .emptyScenarioID: "A continuity scenario ID is required."
        case .duplicateScenarioID(let id): "Continuity scenario ID is duplicated: \(id)."
        case .unknownLanguage(let language): "Unsupported continuity fixture language: \(language)."
        case .emptyInput(let id): "Continuity scenario input is empty: \(id)."
        case .emptyFollowUp(let id): "Continuity scenario follow-up is empty: \(id)."
        case .duplicateLanguageMode(let pair): "Continuity language/mode pair is duplicated: \(pair)."
        case .missingLanguageMode(let pairs): "Continuity language/mode pairs are missing: \(pairs.joined(separator: ", "))."
        }
    }
}

enum MemoryContinuityAssertions {
    static func establishmentFailures(
        memories: [StateEvolutionMemorySnapshot], mode: MemoryContinuityMode,
        sourceExecutionID: String, sourceReference: String
    ) -> [String] {
        var failures: [String] = []
        guard memories.count == 1 else {
            failures.append("establishment_memory_count_mismatch")
            return failures
        }
        let memory = memories[0]
        let expectedOrigin = mode == .automatic ? "observedUserStatement" : "explicitUser"
        let expectedAuthority = mode == .automatic ? "observedUser" : "explicitUser"

        if !memory.detailAvailable || memory.detailErrorCode != nil {
            failures.append("establishment_memory_details_unavailable")
        }
        if memory.origin != expectedOrigin {
            failures.append("establishment_origin_mismatch")
        }
        if memory.authority != expectedAuthority {
            failures.append("establishment_authority_mismatch")
        }
        if !memory.isCurrent || memory.state != "active" || memory.lifecycle != "active" {
            failures.append("establishment_memory_not_current")
        }
        if memory.revision != 1 || memory.revisionNumbers != [1] {
            failures.append("establishment_revision_mismatch")
        }
        if memory.forgottenAt != nil {
            failures.append("establishment_memory_forgotten")
        }
        if memory.retraction != nil {
            failures.append("establishment_retraction_present")
        }
        if memory.supersededByID != nil || !memory.previousMemoryIDs.isEmpty {
            failures.append("establishment_replacement_or_history_present")
        }
        if memory.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
            memory.revisionBodyCount != 1 {
            failures.append("establishment_memory_body_unavailable")
        }
        if memory.evidenceCount != 1 || memory.evidenceExcerptCount != 1 || memory.evidenceHashCount != 1 ||
            memory.evidenceSourceReferences != [sourceReference] || memory.evidenceExecutionIDs != [sourceExecutionID] {
            failures.append("establishment_source_evidence_mismatch")
        }
        return failures
    }

    static func preservationFailures(
        memories: [StateEvolutionMemorySnapshot], baseline: StateEvolutionMemorySnapshot?
    ) -> [String] {
        var failures = StateEvolutionAssertions.preservationFailures(
            memories: memories, baseline: baseline, mutationInvocationCount: 0)
        guard let baseline else { return failures }
        guard let current = memories.first(where: { $0.id == baseline.id }) else { return failures }

        if !current.detailAvailable || current.detailErrorCode != nil {
            failures.append("continuity_memory_details_unavailable")
        }
        if current.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            failures.append("continuity_memory_body_unavailable")
        }
        if current.evidenceSourceReferences.isEmpty || current.evidenceExecutionIDs.isEmpty ||
            current.evidenceCount == 0 || current.evidenceExcerptCount == 0 || current.evidenceHashCount == 0 {
            failures.append("continuity_source_evidence_unavailable")
        }
        if current.revisionNumbers.isEmpty || current.revisionBodyCount == 0 {
            failures.append("continuity_revision_history_unavailable")
        }
        return failures
    }
}

enum MemoryContinuityCitationAssertions {
    static func failures(answer: String, requiresCitation: Bool) -> [String] {
        let references = MemoryCitationReference.references(in: answer)
        var failures = Set<String>()
        if requiresCitation && references.isEmpty {
            failures.insert("required_memory_citation_missing")
        }

        guard let expression = try? NSRegularExpression(pattern: #"memory:[^\s\[\](),]*"#) else {
            return failures.sorted()
        }
        let range = NSRange(answer.startIndex..., in: answer)
        expression.enumerateMatches(in: answer, range: range) { match, _, _ in
            guard let match, let tokenRange = Range(match.range, in: answer) else { return }
            let token = String(answer[tokenRange])
            let before = tokenRange.lowerBound > answer.startIndex ? answer[answer.index(before: tokenRange.lowerBound)] : nil
            let after = tokenRange.upperBound < answer.endIndex ? answer[tokenRange.upperBound] : nil
            let isCanonical = MemoryCitationReference(rawValue: token) != nil
            if !isCanonical {
                failures.insert("malformed_memory_citation")
            } else if before != "[" || after != "]" {
                failures.insert("memory_citation_not_bracketed")
            }
        }
        return failures.sorted()
    }
}
