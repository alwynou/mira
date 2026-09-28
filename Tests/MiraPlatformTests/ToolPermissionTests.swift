import Foundation
import MiraCore
import Testing

@Suite("Global tool permissions")
struct ToolPermissionTests {
    @MainActor @Test func preferencePersistsAndUnknownValuesFailClosed() throws {
        let suite = "mira-permissions-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ToolPermissionPreferences(defaults: defaults)
        #expect(preferences.level == .ask)
        for level in ToolPermissionLevel.allCases {
            preferences.select(level)
            #expect(ToolPermissionPreferences(defaults: defaults).level == level)
        }
        defaults.set("unrecognized", forKey: ToolPermissionPreferences.storageKey)
        #expect(ToolPermissionPreferences(defaults: defaults).level == .ask)
    }

    @Test func policyCoversNonBashToolsAndPreservesRoutineMemoryBehavior() throws {
        for proposal in [
            proposal("memory.delete", effect: .localWrite, namespace: "memory.delete"),
            proposal("files.write", effect: .externalWrite),
            proposal("network.fetch", effect: .read),
            proposal("unknown.mutation", effect: .localWrite, namespace: "unknown")
        ] {
            for level in [ToolPermissionLevel.ask, .automatic] {
                guard case .requireApproval(let prompt, _) = try decision(proposal, level) else {
                    Issue.record("Guarded action escaped review"); continue
                }
                #expect(prompt.contains(proposal.descriptor.definition.name))
                #expect(prompt.contains("fixture-target"))
            }
            #expect(isAllowed(try decision(proposal, .fullAccess)))
        }
        for proposal in [
            proposal("memory.search", effect: .read),
            proposal("memory.remember", effect: .localWrite, namespace: "memory.remember"),
            proposal("memory.retract", effect: .localWrite, namespace: "memory.retract"),
            proposal("task.change", effect: .localWrite, namespace: "tasks.change")
        ] {
            #expect(isAllowed(try decision(proposal, .ask)))
        }
        #expect(!isAllowed(try decision(proposal("memory.remember", effect: .externalWrite), .automatic)))
    }

    @Test func readOnlyCommandsArePinnedAndOnlyAutomaticModeSkipsReview() throws {
        for command in ["pwd", "pwd -P", "ls -lah .", "cat 'file with spaces.txt'", "head ./notes.md", "tail /tmp/notes", "wc -l ./notes"] {
            let canonical = try #require(MacBashReadOnlyCommand.canonical(command))
            #expect(canonical.hasPrefix("/bin/") || canonical.hasPrefix("/usr/bin/"))
            #expect(MacBashReadOnlyCommand.canonical(canonical) == canonical)
            let proposal = bash(canonical)
            #expect(!isAllowed(try decision(proposal, .ask)))
            #expect(isAllowed(try decision(proposal, .automatic)))
            #expect(isAllowed(try decision(proposal, .fullAccess)))
        }
        // PATH-based execution must not be approved by the policy before preparation pins it.
        #expect(!isAllowed(try decision(bash("ls"), .automatic)))
    }

    @Test(arguments: [
        "ls; touch marker", "ls && touch marker", "ls | cat", "ls > marker", "cat < marker",
        "ls $(touch marker)", "ls `touch marker`", "ls $HOME", "ls\ntouch marker", "ls\t/tmp",
        "PATH=/tmp ls", "env ls", "bash -c pwd", "python -c pass", "curl https://example.invalid",
        "git status", "find . -exec sh ;", "sed -i x file", "rm file", "touch file", "ls *", "ls # comment",
        "ls --unknown", "tail -f file", "head -c 99999 file", "pwd /tmp", "cat -file", "ls 'unterminated",
        "ls '\"'", "ls ''", "./ls", "/tmp/ls", "ls /tmp/$(touch marker)", "ls \\; touch marker"
    ])
    func uncertainShellSyntaxRequiresReview(_ command: String) throws {
        #expect(MacBashReadOnlyCommand.canonical(command) == nil)
        #expect(!isAllowed(try decision(bash(command), .automatic)))
    }

    @Test func oversizedReviewIsNotSilentlyTruncated() throws {
        #expect(MacBashReadOnlyCommand.canonical("ls " + String(repeating: "a ", count: 700)) == nil)
        let action = proposal("files.write", effect: .externalWrite, input: .object(["text": .string(String(repeating: "x", count: 5_000))]))
        #expect(throws: MiraError.self) { try decision(action, .ask) }
        #expect(isAllowed(try decision(action, .fullAccess)))
    }

    private func decision(_ proposal: AgentToolProposal, _ level: ToolPermissionLevel) throws -> AgentToolPolicyDecision {
        try MacToolPermissionPolicy.decision(for: proposal, level: level, now: Date(timeIntervalSince1970: 1_000))
    }
    private func isAllowed(_ decision: AgentToolPolicyDecision) -> Bool {
        if case .allow = decision { return true }; return false
    }
    private func bash(_ command: String) -> AgentToolProposal {
        .init(descriptor: MacBashTool().descriptor, effect: .externalWrite, businessNamespace: nil,
              callDigest: String(repeating: "0", count: 64), inheritedSources: [],
              plan: .init(input: MacBashCommand(command: command, workingDirectory: "/tmp", timeoutSeconds: 5).input,
                          sources: [], targets: []))
    }
    private func proposal(_ name: String, effect: SessionEffectKind, namespace: String? = nil,
                          input: JSONValue = .object(["target": .string("fixture-target")])) -> AgentToolProposal {
        let schema = JSONValue.object(["type": .string("object")])
        return .init(descriptor: .init(definition: .init(name: name, description: "Synthetic action", inputSchema: schema),
                                      revision: 1, outputSchema: schema, executionMode: .exclusive,
                                      timeoutMilliseconds: 1_000, maximumResultBytes: 1_024),
                     effect: effect, businessNamespace: namespace, callDigest: String(repeating: "0", count: 64),
                     inheritedSources: [], plan: .init(input: input, sources: [], targets: []))
    }
}
