import Foundation

/// A small literal grammar, not a shell danger detector. Everything else requires review.
enum MacBashReadOnlyCommand {
    static func canonical(_ command: String) -> String? {
        guard let words = words(command), let first = words.first else { return nil }
        let executables = ["pwd": "/bin/pwd", "ls": "/bin/ls", "cat": "/bin/cat",
                           "head": "/usr/bin/head", "tail": "/usr/bin/tail", "wc": "/usr/bin/wc"]
        guard let name = executables.first(where: { $0.key == first || $0.value == first })?.key,
              let executable = executables[name] else { return nil }
        let flags: Set<String>
        switch name {
        case "pwd": flags = ["-L", "-P"]
        case "ls": flags = ["-a", "-A", "-l", "-h", "-la", "-al", "-lah", "-lh", "-1", "-d", "-R"]
        case "cat": flags = ["-n", "-b", "-s", "-v", "-e", "-t"]
        case "wc": flags = ["-c", "-l", "-w", "-m"]
        default: flags = []
        }
        var operands = false
        for word in words.dropFirst() {
            if !operands, flags.contains(word) { continue }
            guard name != "pwd", !word.isEmpty, !word.hasPrefix("-") else { return nil }
            operands = true
        }
        let canonical = ([executable] + words.dropFirst().map { "'" + $0 + "'" }).joined(separator: " ")
        return canonical.utf8.count <= 2_048 ? canonical : nil
    }

    private static func words(_ command: String) -> [String]? {
        // Reject expansions, escapes, operators, globbing, comments and control characters,
        // even inside quotes. Literal paths containing those characters simply require review.
        let forbidden = CharacterSet(charactersIn: "$`\\;|&<>*?[]{}()!#~")
            .union(.controlCharacters)
        guard command.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        var result: [String] = [], word = "", quote: Character?, started = false
        for character in command {
            if let delimiter = quote {
                if character == delimiter { quote = nil }
                else if character == "'" || character == "\"" { return nil }
                else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character; started = true
            } else if character == " " {
                if started { result.append(word); word = ""; started = false }
            } else { word.append(character); started = true }
        }
        guard quote == nil else { return nil }
        if started { result.append(word) }
        return result
    }
}
