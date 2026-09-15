#if DEBUG
    import Foundation
    import MiraCore
    import MiraProviders

    /// A deterministic, network-free model module used only by explicit debug demo hosts and tests.
    struct MacDemoModule: RuntimeModule, Sendable {
        static let adapterIdentity = AgentAdapterIdentity(id: "mac.demo", revision: 1)
        static let connectionSchema = AgentConfigurationIdentity(id: "mac.demo.connection", revision: 1)
        static let routeSchema = AgentConfigurationIdentity(id: "mac.demo.route", revision: 1)
        static let modelID = "mira-demo"
        static let connectionID = ConnectionID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E201")!)
        static let modelDescriptorID = ModelDescriptorID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E202")!)
        static let routeID = RouteID(modelDescriptorID.rawValue)
        static let verifyMultiroundFlow = ProcessInfo.processInfo.arguments.contains("--verify-multiround-flow")
        static let verifyCodeScrolling = ProcessInfo.processInfo.arguments.contains("--verify-code-scrolling")

        let id = "mac.demo"
        let dependencies: Set<String> = []
        let registry: RuntimeRegistry<AgentCapability>
        let stress: Bool
        let verifyConversationFlow: Bool
        let verifyMultiroundFlow: Bool
        let verifyCodeScrolling: Bool

        init(registry: RuntimeRegistry<AgentCapability>, stress: Bool = false,
             verifyConversationFlow: Bool = ProcessInfo.processInfo.arguments.contains("--verify-conversation-flow"),
             verifyMultiroundFlow: Bool = MacDemoModule.verifyMultiroundFlow,
             verifyCodeScrolling: Bool = MacDemoModule.verifyCodeScrolling) {
            self.registry = registry
            self.stress = stress
            self.verifyConversationFlow = verifyConversationFlow
            self.verifyMultiroundFlow = verifyMultiroundFlow
            self.verifyCodeScrolling = verifyCodeScrolling
        }

        func activate(in scope: RuntimeScope) async throws {
            try await registry.register(
                id: "mac.demo.model",
                value: .model(MacDemoModel(stress: stress, verifyConversationFlow: verifyConversationFlow,
                                           verifyMultiroundFlow: verifyMultiroundFlow,
                                           verifyCodeScrolling: verifyCodeScrolling)), scope: scope)
            if verifyMultiroundFlow {
                try await registry.register(
                    id: "demo.source.read", value: .tool(.read(MacDemoSourceReadTool())), scope: scope, order: 0)
            }
            try await registry.register(
                id: "mac.demo.configuration", value: .modelConfiguration(MacDemoConfiguration()), scope: scope)
        }

        /// Seeds only an empty settings collection. A local demo never creates or reads a credential.
        static func seed(in group: MacLibraryWorkloads) async throws {
            let connections = try await group.modelSettings.connections(after: nil, limit: 128)
            let saved: AgentConfiguredConnection
            if let existing = connections.first(where: { $0.id == connectionID }) {
                guard isDemoConnection(existing) else { return }
                saved = existing
            } else {
                guard connections.isEmpty else { return }
                let connection = AgentConfiguredConnection(
                    id: connectionID, revision: 1, configurationRevision: 1,
                    name: "Mira Local Demo", isEnabled: true, definitionID: "mira.demo",
                    endpoints: [.init(id: "demo", configuration: .init(schema: connectionSchema, value: .object([:])), credential: nil)],
                    discovery: nil,
                    defaultInvocation: .init(adapter: adapterIdentity, endpointID: "demo",
                        configuration: .init(schema: routeSchema, value: .object([:]))))
                saved = try await group.credentialSettings.saveConnection(
                    id: connection.id, name: connection.name, isEnabled: connection.isEnabled,
                    definitionID: connection.definitionID, endpoints: connection.endpoints,
                    discovery: connection.discovery, defaultInvocation: connection.defaultInvocation,
                    previous: nil, credentialEndpointID: connection.endpoints[0].id, credential: .keep
                ).connection
            }

            let expectedModel = AgentConfiguredModel(
                id: modelDescriptorID, revision: 1, authorizationRevision: 1,
                reference: .init(connectionID: saved.id, modelID: modelID), displayName: "Mira Local Demo",
                isEnabled: true, invocations: [.init(id: "demo", revision: 1, adapter: adapterIdentity,
                    endpointID: "demo", contextWindow: 32_768, maximumOutputTokens: 12_000,
                    capabilities: [AgentModelCapabilityID.streamingText: .declared,
                                   AgentModelCapabilityID.thinking: .declared,
                                   AgentModelCapabilityID.toolCalls: ProcessInfo.processInfo.arguments.contains("--verify-multiround-flow") ? .declared : .failed],
                    configuration: .init(schema: routeSchema, value: .object([:])),
                    parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
            let expectedPreset = AgentRoutePreset(
                id: routeID, revision: 1, name: "Mira Local Demo",
                modelDescriptorID: expectedModel.id, invocationID: "demo",
                maximumOutputTokens: ProcessInfo.processInfo.arguments.contains("--verify-multiround-flow") ? 1_024 : 12_000,
                configuration: .init(schema: routeSchema, value: .object([:])))
            let currentModel = try await group.modelSettings.model(id: modelDescriptorID)
            let currentPreset = try await group.modelSettings.preset(id: routeID)
            if let currentModel {
                guard currentModel.reference == expectedModel.reference,
                    currentModel.isEnabled, currentModel.invocations == expectedModel.invocations
                else { return }
            }
            if let currentPreset {
                guard currentPreset.modelDescriptorID == expectedPreset.modelDescriptorID,
                    currentPreset.name == expectedPreset.name,
                    currentPreset.maximumOutputTokens == expectedPreset.maximumOutputTokens,
                    currentPreset.configuration == expectedPreset.configuration
                else { return }
            }
            if currentModel != nil {
                if currentPreset == nil {
                    try await group.modelSettings.savePreset(expectedPreset, expectedRevision: nil)
                }
            } else {
                try await group.modelSettings.savePoolModel(
                    expectedModel, preset: expectedPreset,
                    expectedModelRevision: nil, expectedPresetRevision: nil)
            }
            let bindings = try await group.modelSettings.bindings(scope: .global)
            if let binding = bindings.first(where: { $0.purpose == AgentModelPurposeID.conversation }) {
                guard binding.routeID == routeID else { return }
            } else {
                try await group.modelSettings.saveBinding(
                    .init(
                        scope: .global, purpose: AgentModelPurposeID.conversation,
                        routeID: routeID, revision: 1), expectedRevision: nil)
            }
            if ProcessInfo.processInfo.arguments.contains("--verify-model-information") {
                let id = ConnectionID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E220")!)
                if try await group.modelSettings.connection(id: id) == nil,
                   let provider = ProviderModelCatalog.bundled.providers.first(where: { $0.id == "deepseek" }) {
                    let reference = try provider.makeConnection(id: id, credential: nil)
                    // Disabled, credential-free fixture: displays catalog facts without allowing requests.
                    _ = try await group.credentialSettings.saveConnection(id: id, name: "DeepSeek", isEnabled: false,
                        definitionID: provider.id, endpoints: reference.endpoints, discovery: nil,
                        defaultInvocation: reference.defaultInvocation, previous: nil,
                        credentialEndpointID: reference.endpoints[0].id, credential: .keep)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--verify-model-selection") {
                try await seedModelChoices(in: group, connection: saved, template: expectedModel, preset: expectedPreset)
            }
        }

        /// Extra offline models are available only to the explicit native selection fixture.
        private static func seedModelChoices(in group: MacLibraryWorkloads, connection: AgentConfiguredConnection,
                                             template: AgentConfiguredModel, preset: AgentRoutePreset) async throws {
            let secondID = ConnectionID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E210")!)
            if try await group.modelSettings.connection(id: secondID) == nil {
                _ = try await group.credentialSettings.saveConnection(id: secondID, name: "Demo Provider B", isEnabled: true,
                    definitionID: "mira.demo", endpoints: connection.endpoints, discovery: nil,
                    defaultInvocation: connection.defaultInvocation, previous: nil,
                    credentialEndpointID: connection.endpoints[0].id, credential: .keep)
            }
            for (identity, modelID, name, connectionID) in [
                ("0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E211", "demo-balanced", "Demo Balanced", connection.id),
                ("0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E212", "demo-fast", "Demo Fast", secondID)
            ] {
                let id = ModelDescriptorID(UUID(uuidString: identity)!)
                guard try await group.modelSettings.model(id: id) == nil else { continue }
                let model = AgentConfiguredModel(id: id, revision: 1, authorizationRevision: 1,
                    reference: .init(connectionID: connectionID, modelID: modelID), displayName: name,
                    isEnabled: true, invocations: template.invocations, facts: [])
                try await group.modelSettings.savePoolModel(model,
                    preset: .init(id: RouteID(id.rawValue), revision: 1, name: name, modelDescriptorID: id,
                        invocationID: preset.invocationID, maximumOutputTokens: preset.maximumOutputTokens,
                        configuration: preset.configuration), expectedModelRevision: nil, expectedPresetRevision: nil)
            }
        }

        private static func isDemoConnection(_ value: AgentConfiguredConnection) -> Bool {
            value.name == "Mira Local Demo" && value.isEnabled
                && value.endpoints.first?.credential == nil
                && value.endpoints.first?.configuration.schema == connectionSchema
                && value.endpoints.first?.configuration.value == .object([:])
        }
    }

    private struct MacDemoConfiguration: AgentModelConfigurationProvider {
        let identity = MacDemoModule.adapterIdentity

        func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
            guard invocation.id == "demo" else {
                throw MiraError(.configuration, "The local demo model is unavailable.")
            }
            return .init(
                adapter: identity, title: "Mira Local Demo", credential: .none,
                connection: schema(MacDemoModule.connectionSchema, title: "Local demo connection"),
                route: schema(MacDemoModule.routeSchema, title: "Local demo route"))
        }

        func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
            let invocation = try candidate.invocation
            let endpoint = try candidate.endpoint
            let descriptor = try descriptor(for: invocation)
            try descriptor.connection.validate(endpoint.configuration)
            try descriptor.route.validate(candidate.preset.configuration)
            guard invocation.adapter == identity,
                endpoint.credential == nil,
                endpoint.configuration.schema == MacDemoModule.connectionSchema,
                candidate.preset.configuration.schema == MacDemoModule.routeSchema
            else {
                throw MiraError(.configuration, "The local demo configuration does not match its registered schema.")
            }
            return .object([:])
        }

        private func schema(_ identity: AgentConfigurationIdentity, title: String) -> AgentConfigurationSchema {
            .init(
                identity: identity, title: title,
                schema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false),
                ]), defaults: .object([:]))
        }
    }

    private struct MacDemoModel: AgentModelAdapter {
        let identity = MacDemoModule.adapterIdentity
        let stress: Bool
        let verifyConversationFlow: Bool
        let verifyMultiroundFlow: Bool
        let verifyCodeScrolling: Bool

        func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
            try input.validate(for: route)
            guard route.adapter == identity else {
                throw MiraError(.configuration, "The local demo adapter does not match the frozen route.")
            }
            let encodedBytes = try SessionCodec.encode(input).count
            let estimatedInputTokens = encodedBytes + 1_024
            let prepared = AgentPreparedModelRequest(
                adapter: identity, input: input, wirePayload: .object([:]),
                estimatedInputTokens: estimatedInputTokens)
            try prepared.validate(for: route)
            return prepared
        }

        func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
            let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
            let stress = stress
            let producer = Task {
                do {
                    if verifyMultiroundFlow {
                        try await Self.emitMultiround(
                            request: request, continuation: continuation)
                        continuation.finish()
                        return
                    }
                    if verifyConversationFlow {
                        continuation.yield(.blockStarted(.init(
                            id: "thinking", content: .thinking(
                                "Reviewing your request and preparing a concise response. "))))
                        for count in 1...20 {
                            try await Task.sleep(for: .milliseconds(200))
                            continuation.yield(.blockDelta(id: "thinking", text: "Step \(count). "))
                        }
                        continuation.yield(.blockFinished(id: "thinking"))
                    } else if stress {
                        continuation.yield(.blockStarted(.init(
                            id: "thinking", content: .thinking(
                                "Reviewing the synthetic rendering fixture, its tables, lists, code, and final marker. "))))
                        for count in 1...20 {
                            try await Task.sleep(for: .milliseconds(25))
                            continuation.yield(.blockDelta(id: "thinking", text: "Step \(count). "))
                        }
                        continuation.yield(.blockFinished(id: "thinking"))
                    }
                    let answer = verifyCodeScrolling
                        ? Self.codeScrollingAnswer
                        : verifyConversationFlow
                        ? Self.conversationFlowAnswer(for: request.input)
                        : stress ? Self.stressAnswer : Self.answer(for: request.input)
                    let characters = Array(answer)
                    let chunkSize = verifyCodeScrolling ? 128 : verifyConversationFlow ? 2 : stress ? 12 : 1
                    let blockID = "answer"
                    continuation.yield(.blockStarted(.init(id: blockID, content: .text(""))))
                    for start in stride(from: 0, to: characters.count, by: chunkSize) {
                        try await Task.sleep(for: .milliseconds(verifyConversationFlow ? 100 : stress ? 8 : 2))
                        continuation.yield(.blockDelta(
                            id: blockID, text: String(characters[start..<min(start + chunkSize, characters.count)])))
                    }
                    continuation.yield(.blockFinished(id: blockID))
                    continuation.yield(.finished(.stop))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: CancellationError())
                }
            }
            return .init(
                events: events,
                cancelAndDrain: {
                    producer.cancel()
                    await producer.value
                })
        }

        func replay(
            _ messages: [AgentModelMessage], from source: AgentModelRoute,
            to target: AgentModelRoute, boundary: AgentReplayBoundary
        ) throws -> AgentReplayDecision { .include(messages) }

        private static func answer(for input: AgentModelInput) -> String {
            let text = input.messages.last(where: { $0.role == .user })?.text ?? ""
            return """
                # Mira Local Demo

                Hello, I am Mira. This reply is generated locally without network or Keychain access.

                You sent:

                > \(text)

                ## Supported Content

                - Headings, lists, and quotes
                - **Emphasis**, `inline code`, and tables
                - Deterministic local streaming
                """
        }

        private static func conversationFlowAnswer(for input: AgentModelInput) -> String {
            let text = input.messages.last(where: { $0.role == .user })?.text ?? ""
            return "I reviewed your request and prepared a concise response. You asked: \(text)"
        }

        /// Deliberately exercises a bounded Markdown code viewport: a short block
        /// precedes a tall block whose lines exceed the narrow native window.
        private static var codeScrollingAnswer: String {
            let longLines = (1...45).map { index in
                "let fixtureLine\(index) = \"The deterministic scrolling fixture keeps this line deliberately wide for horizontal overflow — \u{4E2D}\u{6587}\u{6D4B}\u{8BD5}\" // line \(index)"
            }.joined(separator: "\n")
            return """
                The rendering fixture begins with prose before the code regions. It includes \u{8FD9}\u{662F}\u{4E00}\u{4E2A} CJK sentence so wrapping remains deterministic.

                ```swift
                let shortFixture = "short code block"
                print(shortFixture)
                ```

                The final block is intentionally long vertically and horizontally. Scroll inside the code region to inspect every line.

                ```swift
                \(longLines)
                CODE BLOCK END
                ```
                """
        }

        private static func emitMultiround(
            request: AgentPreparedModelRequest,
            continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation
        ) async throws {
            let completedToolResults = request.input.messages.reduce(into: 0) { count, message in
                count += message.toolResults.count
            }
            let round = completedToolResults
            switch round {
            case 0:
                try await emitRound(
                    thinking: ProcessInfo.processInfo.arguments.contains("--verify-tool-presentation")
                        ? String(repeating: "Reviewing the synthetic source and its supporting details. ", count: 5)
                        : "First round reasoning",
                    text: "I will inspect the first source.",
                    call: .init(id: "demo-read-first", name: "demo.source.read",
                                 arguments: #"{"source":"first"}"#), continuation: continuation)
            case 1:
                try await emitRound(
                    thinking: "Second round reasoning",
                    text: "I will inspect the second source.",
                    call: .init(id: "demo-read-second", name: "demo.source.read",
                                 arguments: #"{"source":"second"}"#), continuation: continuation)
            default:
                try await emitRound(
                    thinking: "Final round reasoning",
                    text: "Both sources agree: alpha and beta.",
                    call: nil, continuation: continuation)
            }
        }

        private static func emitRound(
            thinking: String, text: String, call: CanonicalToolCall?,
            continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation
        ) async throws {
            let thinkingID = "thinking-\(thinking.prefix(1))"
            continuation.yield(.blockStarted(.init(id: thinkingID, content: .thinking(thinking))))
            try await Task.sleep(for: .milliseconds(call?.id == "demo-read-first" ? 5_000 : 120))
            continuation.yield(.blockFinished(id: thinkingID))
            let textID = "text-\(thinking.prefix(1))"
            continuation.yield(.blockStarted(.init(id: textID, content: .text(text))))
            try await Task.sleep(for: .milliseconds(120))
            continuation.yield(.blockFinished(id: textID))
            if let call {
                continuation.yield(.blockStarted(.init(id: call.id, content: .toolCall(call))))
                try await Task.sleep(for: .milliseconds(120))
                continuation.yield(.blockFinished(id: call.id))
            }
            continuation.yield(.finished(call == nil ? .stop : .toolCalls))
            try await Task.sleep(for: .milliseconds(120))
        }

        private static let stressAnswer: String = {
            var result = "# Rendering stress fixture\n\n"
            for index in 1...24 {
                result += """
                    ## Section \(index)

                    This synthetic paragraph verifies stable Markdown measurement during streaming, resizing, selection, and rapid scrolling. **Emphasis**, `inline code`, and [a link](https://www.swift.org) remain available.

                    - First item with a longer explanation that wraps over several lines in a narrow window.
                        - Nested item with **strong text** and a detail to read.
                    - Second item with a short explanation.

                    > A block quote with sufficient text to wrap onto another line and exercise the paragraph layout cache.

                    ```swift
                    let section = \(index)
                    let values = (0..<8).map { $0 * section }
                    print(values)
                    ```

                    | Column A | Column B | Column C | Column D |
                    | --- | --- | --- | --- |
                    | A long wrapping value for section \(index) | Another wrapping value | Small | Complete |
                    | One | Two | Three | Four |

                    Inline math: $a^2 + b^2 = c^2$.

                    """
            }
            return result + "## End of rendering fixture\n\nThe final stream marker is visible.\n"
        }()
    }

    struct MacDemoSourceReadTool: AgentReadTool {
        let policy: AgentToolPolicyRequirement = .hostOnly

        var descriptor: AgentToolDescriptor {
            .init(
                definition: .init(
                    name: "demo.source.read",
                    description: "Read one deterministic synthetic source for the offline conversation fixture.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object(["source": .object(["type": .string("string"), "enum": .array([.string("first"), .string("second")])])]),
                        "required": .array([.string("source")]),
                        "additionalProperties": .bool(false)
                    ])),
                revision: 1,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object(["type": .string("string")]),
                        "result": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("source"), .string("result")]),
                    "additionalProperties": .bool(false)
                ]),
                executionMode: .ordered, timeoutMilliseconds: 30_000, maximumResultBytes: 4_096)
        }

        func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
            let normalized = try ToolSchemaValidator.decode(
                try arguments.jsonString(), schema: descriptor.definition.inputSchema)
            guard let source = normalized["source"]?.stringValue else {
                throw MiraError(.invalidInput, "The demo source is missing.")
            }
            return .init(input: .object(["source": .string(source)]), sources: [], targets: [])
        }

        func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
            try plan.validate()
            guard let source = plan.input["source"]?.stringValue else {
                throw MiraError(.invalidInput, "The demo source is missing.")
            }
            if source == "first", ProcessInfo.processInfo.arguments.contains("--verify-tool-presentation") {
                throw MiraError(.notFound, "The synthetic source could not be read.")
            }
            let result: String
            switch source {
            case "first": result = "First source result: alpha"
            case "second": result = "Second source result: beta"
            default: throw MiraError(.notFound, "The demo source is unavailable.")
            }
            return .object(["source": .string(source), "result": .string(result)])
        }
    }
#endif
