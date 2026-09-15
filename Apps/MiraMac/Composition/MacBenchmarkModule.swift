#if DEBUG
    import Foundation
    import MiraCore

    /// A deterministic, network-free driver used only by explicit presentation benchmarks.
    struct MacBenchmarkModule: RuntimeModule, Sendable {
        static let driverID = "mac.benchmark"
        static let driverRevision = 1
        static let sessionIDs = [
            ConversationID(UUID(uuidString: "A8B20D64-7E5C-4A38-8A25-3D4B2E7F1001")!),
            ConversationID(UUID(uuidString: "A8B20D64-7E5C-4A38-8A25-3D4B2E7F1002")!),
        ]

        let id = "mac.benchmark"
        let dependencies: Set<String> = []
        let registry: RuntimeRegistry<AgentCapability>
        let stress: Bool

        init(registry: RuntimeRegistry<AgentCapability>, stress: Bool = false) {
            self.registry = registry
            self.stress = stress
        }

        func activate(in scope: RuntimeScope) async throws {
            try await registry.register(
                id: "mac.benchmark.driver",
                value: .driver(MacBenchmarkDriver(stress: stress)),
                scope: scope)
        }

        /// Creates history through the application runtime so the benchmark exercises
        /// the current journal, query projection, and page lifecycle.
        static func seed(in group: MacLibraryWorkloads, turns: [Int] = [50, 60]) async throws -> [ConversationID] {
            guard turns.count == sessionIDs.count, turns.allSatisfy({ (1...256).contains($0) }) else {
                throw MiraError(.configuration, "The benchmark history shape is invalid.")
            }
            try await group.queries.synchronizeLibrary()
            var result: [ConversationID] = []
            for (index, sessionID) in sessionIDs.enumerated() {
                let title = "Synthetic Switch \(index + 1)"
                let existing = try await group.queries.messagePage(sessionID: sessionID, limit: 128)
                if existing.session == nil {
                    try requireCommitted(
                        await group.application.createSession(
                            id: sessionID, commandID: UUID(), title: title, workspaceID: nil))
                } else {
                    guard existing.session?.title.text == title else {
                        throw MiraError(.conflict, "The benchmark session belongs to another fixture.")
                    }
                }

                let state = try await group.application.sessionSnapshot(id: sessionID)
                var completedTurns = state.executionOrder.filter {
                    state.executions[$0]?.completion?.status == .completed
                }.count
                guard completedTurns == state.executionOrder.count else {
                    throw MiraError(.conflict, "The benchmark session contains an unfinished execution.")
                }
                while completedTurns < turns[index] {
                    let executionID = ExecutionID()
                    let command = AgentSubmitCommand(
                        id: UUID(), sessionID: sessionID, executionID: executionID,
                        input: .message(
                            id: MessageID(), text: fixtureText(sequence: completedTurns * 2, role: "user"),
                            timeZoneIdentifier: "UTC"),
                        options: .init(
                            driverID: driverID, driverRevision: driverRevision,
                            instructions: "Use the deterministic local benchmark driver.",
                            route: nil))
                    try requireCommitted(await group.application.submit(command))
                try requireCommitted(
                    await group.application.waitForExecution(id: executionID, sessionID: sessionID))
                let settled = try await group.application.sessionSnapshot(id: sessionID)
                guard settled.executions[executionID]?.completion?.status == .completed else {
                    throw MiraError(.conflict, "The benchmark session contains an unfinished execution.")
                }
                    completedTurns += 1
                }
                result.append(sessionID)
            }
            try await group.queries.synchronizeLibrary()
            return result
        }

        private static func requireCommitted(_ result: SessionCommitResult) throws {
            switch result {
            case .committed: return
            case .notCommitted(let error), .indeterminate(_, let error): throw error
            }
        }

        private static func fixtureText(sequence: Int, role: String) -> String {
            let heading = sequence % 5 == 1 ? "\n\n## Synthetic section \(sequence / 5)\n" : ""
            let code =
                sequence.isMultiple(of: 7)
                ? "\n\n```swift\nlet syntheticValue_\(sequence) = \(sequence)\nprint(syntheticValue_\(sequence))\n```\n"
                : ""
            let paragraph = String(
                repeating: "Synthetic variable-height transcript content for conversation switching. ",
                count: sequence.isMultiple(of: 3) ? 6 : 2)
            return "\(role.capitalized) message \(sequence).\(heading)\n\n\(paragraph)\(code)"
        }
    }

    private struct MacBenchmarkDriver: AgentDriver {
        let id = MacBenchmarkModule.driverID
        let revision = MacBenchmarkModule.driverRevision
        let stress: Bool

        func run(in context: AgentRunContext) async throws -> AgentDriverDecision {
            let text = stress ? Self.stressAnswer(for: context.userText) : Self.answer(for: context.userText)
            return .respond(text: text)
        }

        private static func answer(for userText: String) -> String {
            """
            # Mira benchmark fixture

            This response is generated by a local deterministic driver without network or credentials.

            > \(userText)

            ## Supported Content

            - Headings, lists, quotes, and code
            - **Emphasis** and `inline code`
            - Stable transcript geometry
            """
        }

        private static func stressAnswer(for userText: String) -> String {
            var result = "# Rendering stress fixture\n\n"
            for index in 1...24 {
                result += """
                    ## Section \(index)

                    This synthetic paragraph verifies stable Markdown measurement during streaming, resizing, selection, and rapid scrolling. **Emphasis**, `inline code`, and [a link](https://www.swift.org) remain available.

                    - First item with a longer explanation that wraps over several lines in a narrow window.
                        - Nested item with **strong text** and a detail to read.
                    - Second item with a short explanation.

                    ```swift
                    let section = \(index)
                    let values = (0..<8).map { $0 * section }
                    print(values)
                    ```

                    | Column A | Column B | Column C | Column D |
                    | --- | --- | --- | --- |
                    | A long wrapping value for section \(index) | Another wrapping value | Small | Complete |
                    | One | Two | Three | Four |

                    """
            }
            return result
                + "User fixture: \(userText)\n\n## End of rendering fixture\n\nThe final stream marker is visible.\n"
        }
    }
#endif
