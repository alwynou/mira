import Foundation
import MiraCore

/// Hides internal memory annotations only in assistant presentation. Journal text
/// and tool evidence stay verbatim; user messages never pass through this filter.
enum AssistantTextPresentation {
    private static let uuid = "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"
    private static let token = "memory:" + uuid + "@[0-9]+"
    private static let links = expression("\\[([^\\]\\n]*)\\]\\(" + token + "\\)")
    private static let references = expression("`" + token + "`|\\[" + token + "\\]|\\(" + token + "\\)|(?<![a-z0-9_])" + token + "(?![a-z0-9_@-])")
    private static let identifiers = expression("`" + uuid + "`|(?<![a-z0-9_-])" + uuid + "(?![a-z0-9_-])")
    private static let incompleteReference = expression("[\\[(`]?memory:[a-f0-9-]*(?:@[0-9]*)?$", options: [.caseInsensitive])

    static func text(_ source: String, memoryIDs: Set<UUID> = [], isStreaming: Bool = false) -> String {
        var result = replacing(links, in: source, with: "$1")
        // A partial reference remains hidden if generation stops mid-token too.
        result = replacing(incompleteReference, in: result)
        result = replacing(references, in: result)
        if !memoryIDs.isEmpty, let identifiers {
            let matches = identifiers.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let id = UUID(uuidString: String(result[range]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))),
                      memoryIDs.contains(id) else { continue }
                result.removeSubrange(range)
            }
        }
        let suffix = String(result.reversed().prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.reversed())
        if !suffix.isEmpty, (isStreaming || suffix.count >= 8),
           memoryIDs.contains(where: { $0.uuidString.lowercased().hasPrefix(suffix.lowercased()) }) {
            result.removeLast(suffix.count)
            if result.last == "`" { result.removeLast() }
        }
        return result
    }

    /// Only memory tool receipts identify bare IDs; unrelated UUIDs remain text.
    static func memoryIDs(in steps: [SessionActivityStep]) -> Set<UUID> {
        var result = Set<UUID>()
        for step in steps {
            for block in step.blocks {
                guard case .tool(let tool) = block.content, tool.toolName.hasPrefix("memory."),
                      let body = tool.result.text,
                      let value = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)) else { continue }
                collectIDs(value, into: &result)
            }
        }
        return result
    }

    private static func collectIDs(_ value: JSONValue, into result: inout Set<UUID>) {
        switch value {
        case .object(let fields):
            if case .string(let raw) = fields["memory_id"], let id = UUID(uuidString: raw) { result.insert(id) }
            for child in fields.values { collectIDs(child, into: &result) }
        case .array(let values):
            for child in values { collectIDs(child, into: &result) }
        default: break
        }
    }

    private static func expression(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func replacing(_ expression: NSRegularExpression?, in source: String, with replacement: String = "") -> String {
        guard let expression else { return source }
        return expression.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: replacement)
    }
}
