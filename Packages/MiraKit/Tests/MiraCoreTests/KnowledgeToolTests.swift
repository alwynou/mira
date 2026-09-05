import Foundation
import Testing
import MiraCore
import MiraData

struct KnowledgeToolTests {
    @Test func registersBoundedReadOnlyToolsWithClosedSchemas() throws {
        let fixture = try KnowledgeToolFixture()
        defer { fixture.cleanup() }
        let tools = KnowledgeTools.readOnly(store: fixture.store)
        #expect(tools.map(\.descriptor.definition.name).sorted() == ["knowledge.search", "source.open", "source.readChunk"])
        for tool in tools {
            #expect(tool.descriptor.sideEffect == .read)
            #expect(tool.descriptor.maxResultBytes <= 32_768)
            try ToolSchemaValidator.validateSchema(tool.descriptor.definition.inputSchema)
            let object = try #require(tool.descriptor.definition.inputSchema["properties"])
            if case .object(let properties) = object {
                #expect(properties.keys.allSatisfy { ["query", "source_id", "version_id", "chunk_id"].contains($0) })
            } else {
                Issue.record("Knowledge tool schema properties are not an object.")
            }
        }
    }

    @Test func searchOpenAndReadChunkReturnExactCitationsAndRecordUsage() async throws {
        let fixture = try KnowledgeToolFixture()
        defer { fixture.cleanup() }
        let tools = KnowledgeTools.readOnly(store: fixture.store)
        let context = fixture.context()
        let search = try #require(tools.first { $0.descriptor.definition.name == "knowledge.search" })
        let searchJSON = try await search.execute(arguments: .object(["query": .string("Swift")]), context: context)
        let searchValue = try JSONDecoder().decode(JSONValue.self, from: Data(searchJSON.utf8))
        let hit = try #require(searchValue["hits"]?.arrayValue?.first)
        #expect(hit["snippet"]?.stringValue?.contains("Swift") == true)
        #expect(hit["reference"]?.stringValue == fixture.chunk.summary.citation)

        let open = try #require(tools.first { $0.descriptor.definition.name == "source.open" })
        let openArgs: JSONValue = .object(["source_id": .string(fixture.source.id.rawValue.uuidString.lowercased()), "version_id": .string(fixture.version.id.rawValue.uuidString.lowercased())])
        let openJSON = try await open.execute(arguments: openArgs, context: context)
        let openValue = try JSONDecoder().decode(JSONValue.self, from: Data(openJSON.utf8))
        #expect(openValue["selected_version"]?["version_id"]?.stringValue == fixture.version.id.rawValue.uuidString.lowercased())
        #expect(openValue["chunks"]?[0]?["reference"] == nil)
        #expect(openValue["chunks"]?[0]?["content"] == nil)

        let read = try #require(tools.first { $0.descriptor.definition.name == "source.readChunk" })
        let readJSON = try await read.execute(arguments: .object(["chunk_id": .string(fixture.chunk.id.rawValue.uuidString.lowercased())]), context: context)
        let readValue = try JSONDecoder().decode(JSONValue.self, from: Data(readJSON.utf8))
        #expect(readValue["content"]?.stringValue == fixture.chunk.text)
        #expect(readValue["reference"]?.stringValue == fixture.chunk.summary.citation)
        try fixture.store.validateSourceUsage(executionID: fixture.execution.id)
    }

    @Test func openingMetadataDoesNotAuthorizeCitationUntilChunkRead() async throws {
        let fixture = try KnowledgeToolFixture()
        defer { fixture.cleanup() }
        let tools = KnowledgeTools.readOnly(store: fixture.store)
        let context = fixture.context()
        let open = try #require(tools.first { $0.descriptor.definition.name == "source.open" })
        let args: JSONValue = .object(["source_id": .string(fixture.source.id.rawValue.uuidString.lowercased())])
        _ = try await open.execute(arguments: args, context: context)
        #expect(throws: MiraError.self) {
            try fixture.store.sourceCitation(.init(versionID: fixture.version.id, chunkID: fixture.chunk.id), executionID: fixture.execution.id, conversationID: fixture.conversation.id)
        }

        let read = try #require(tools.first { $0.descriptor.definition.name == "source.readChunk" })
        _ = try await read.execute(arguments: .object(["chunk_id": .string(fixture.chunk.id.rawValue.uuidString.lowercased())]), context: context)
        let citation = try fixture.store.sourceCitation(.init(versionID: fixture.version.id, chunkID: fixture.chunk.id), executionID: fixture.execution.id, conversationID: fixture.conversation.id)
        #expect(citation.chunk.id == fixture.chunk.id)
    }

    @Test func rejectsInvalidOptionalVersionAndDirectExtraArguments() async throws {
        let fixture = try KnowledgeToolFixture()
        defer { fixture.cleanup() }
        let open = try #require(KnowledgeTools.readOnly(store: fixture.store).first { $0.descriptor.definition.name == "source.open" })
        let context = fixture.context()
        await #expect(throws: MiraError.self) {
            try await open.execute(arguments: .object(["source_id": .string(fixture.source.id.rawValue.uuidString), "version_id": .string("not-a-uuid")]), context: context)
        }
        await #expect(throws: MiraError.self) {
            try await open.execute(arguments: .object(["source_id": .string(fixture.source.id.rawValue.uuidString), "unexpected": .string("value")]), context: context)
        }
    }

    @Test func rejectsMismatchedLiveContextAndRevokedSource() async throws {
        let fixture = try KnowledgeToolFixture()
        defer { fixture.cleanup() }
        let tool = try #require(KnowledgeTools.readOnly(store: fixture.store).first { $0.descriptor.definition.name == "source.readChunk" })
        var wrongMessage = fixture.context()
        wrongMessage.userMessageID = MessageID()
        await #expect(throws: MiraError.self) {
            try await tool.execute(arguments: .object(["chunk_id": .string(fixture.chunk.id.rawValue.uuidString.lowercased())]), context: wrongMessage)
        }

        _ = try fixture.store.setSourceRemoteUse(fixture.source.id, workspaceID: nil, allowed: false, expectedRevision: fixture.source.revision, at: Date())
        await #expect(throws: MiraError.self) {
            try await tool.execute(arguments: .object(["chunk_id": .string(fixture.chunk.id.rawValue.uuidString.lowercased())]), context: fixture.context())
        }
    }
}

private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard case .array(let values) = self, values.indices.contains(index) else { return nil }
        return values[index]
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }
}

private struct KnowledgeToolFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let conversation: Conversation
    let execution: Execution
    let source: KnowledgeSource
    let version: KnowledgeSourceVersion
    let chunk: SourceChunk

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraKnowledgeTools-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        try store.saveConnection(connection, expectedRevision: nil)
        let model = ModelDescriptor(connectionID: connection.id, connectionRevision: connection.revision, modelID: "fixture", contextWindow: 65_536, textCapability: .declared, toolCapability: .declared)
        try store.saveModel(model, expectedRevision: nil)
        let route = ModelRoute(name: "Synthetic", modelDescriptorID: model.id)
        try store.saveRoute(route, expectedRevision: nil)
        try store.saveRouteBinding(RouteBinding(scope: .global, purpose: .conversation, routeID: route.id), expectedRevision: nil)

        conversation = Conversation(id: .init(), workspaceID: nil, title: "Knowledge fixture", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let resolved = try store.modelConfiguration().resolve(purpose: .conversation, explicitRouteID: route.id, conversation: conversation)
        execution = try store.enqueue(conversationID: conversation.id, text: "Find the local source", route: resolved, executionID: .init(), messageID: .init(), at: .now)

        let file = directory.appendingPathComponent("guide.md")
        let text = "# Guide\nSwift types and local file paths are documented here.\n\n## Details\nUse source.readChunk for exact evidence.\n"
        try Data(text.utf8).write(to: file)
        let receipt = try store.importMarkdownFile(file, workspaceID: nil, updating: nil, expectedRevision: nil, at: .now)
        source = try store.setSourceRemoteUse(receipt.source.id, workspaceID: nil, allowed: true, expectedRevision: receipt.source.revision, at: .now)
        version = receipt.version
        let detail = try store.knowledgeSource(source.id, versionID: version.id, workspaceID: nil, connectionID: connection.id)
        let summary = try #require(detail.chunks.first)
        chunk = try store.sourceChunk(summary.id, workspaceID: nil, connectionID: connection.id)
    }

    func context() -> ToolContext {
        .init(executionID: execution.id, invocationID: UUID(), workspaceID: conversation.workspaceID, userMessageID: execution.triggerMessageID, userText: "Find the local source")
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
