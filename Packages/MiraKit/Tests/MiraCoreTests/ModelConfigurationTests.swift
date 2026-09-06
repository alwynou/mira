import Foundation
import Testing
import MiraCore

struct ModelConfigurationTests {
    @Test func explicitConversationWorkspaceAndGlobalBindingsHaveOrderedPrecedence() throws {
        let fixture = RoutingFixture()
        let workspace = Workspace(id: .init(), name: "Team", allowedConnectionIDs: nil)
        let conversation = Conversation(id: .init(), workspaceID: workspace.id, title: "", createdAt: .now, updatedAt: .now)
        let global = makeRoute(name: "Global", modelDescriptorID: fixture.model.id)
        let workspaceRoute = makeRoute(name: "Workspace", modelDescriptorID: fixture.model.id)
        let conversationRoute = makeRoute(name: "Conversation", modelDescriptorID: fixture.model.id)
        let explicit = makeRoute(name: "Explicit", modelDescriptorID: fixture.model.id)
        let configuration = ModelConfiguration(
            connections: [fixture.connection],
            models: [fixture.model],
            routes: [global, workspaceRoute, conversationRoute, explicit],
            bindings: [
                .init(scope: .global, purpose: .conversation, routeID: global.id),
                .init(scope: .workspace(workspace.id), purpose: .conversation, routeID: workspaceRoute.id),
                .init(scope: .conversation(conversation.id), purpose: .conversation, routeID: conversationRoute.id)
            ]
        )

        #expect(try configuration.resolve(purpose: .conversation, explicitRouteID: explicit.id, conversation: conversation, workspace: workspace).id == explicit.id)
        #expect(try configuration.resolve(purpose: .conversation, conversation: conversation, workspace: workspace).id == conversationRoute.id)
        #expect(try configuration.resolve(purpose: .conversation, conversation: Conversation(id: .init(), workspaceID: workspace.id, title: "", createdAt: .now, updatedAt: .now), workspace: workspace).id == workspaceRoute.id)
        #expect(try configuration.resolve(purpose: .conversation).id == global.id)
    }

    @Test func purposesResolveIndependentlyAtTheSameScope() throws {
        let fixture = RoutingFixture()
        let conversationRoute = makeRoute(name: "Conversation", modelDescriptorID: fixture.model.id)
        let memoryRoute = makeRoute(name: "Memory", modelDescriptorID: fixture.model.id)
        let configuration = ModelConfiguration(
            connections: [fixture.connection], models: [fixture.model], routes: [conversationRoute, memoryRoute],
            bindings: [
                .init(scope: .global, purpose: .conversation, routeID: conversationRoute.id),
                .init(scope: .global, purpose: .memoryExtraction, routeID: memoryRoute.id)
            ]
        )

        let conversation = try configuration.resolve(purpose: .conversation)
        let memory = try configuration.resolve(purpose: .memoryExtraction)
        #expect(conversation.id == conversationRoute.id)
        #expect(conversation.purpose == .conversation)
        #expect(memory.id == memoryRoute.id)
        #expect(memory.purpose == .memoryExtraction)
    }

    @Test func missingOrDanglingSelectionRejectsWithoutFallingBack() throws {
        let fixture = RoutingFixture()
        let global = makeRoute(name: "Global", modelDescriptorID: fixture.model.id)
        let workspace = Workspace(id: .init(), name: "Team")
        let conversation = Conversation(id: .init(), workspaceID: workspace.id, title: "", createdAt: .now, updatedAt: .now)
        let configuration = ModelConfiguration(
            connections: [fixture.connection], models: [fixture.model], routes: [global],
            bindings: [
                .init(scope: .global, purpose: .conversation, routeID: global.id),
                .init(scope: .conversation(conversation.id), purpose: .conversation, routeID: .init())
            ]
        )

        expectError(.configuration) {
            _ = try configuration.resolve(purpose: .conversation, explicitRouteID: .init(), conversation: conversation, workspace: workspace)
        }
        expectError(.configuration) {
            _ = try configuration.resolve(purpose: .conversation, conversation: conversation, workspace: workspace)
        }
    }

    @Test func workspaceMismatchAndConnectionPolicyAreEnforced() throws {
        let fixture = RoutingFixture()
        let route = makeRoute(name: "Global", modelDescriptorID: fixture.model.id)
        let configuration = ModelConfiguration(
            connections: [fixture.connection], models: [fixture.model], routes: [route],
            bindings: [.init(scope: .global, purpose: .conversation, routeID: route.id)]
        )
        let workspaceID = WorkspaceID()
        let otherWorkspaceID = WorkspaceID()
        let conversation = Conversation(id: .init(), workspaceID: otherWorkspaceID, title: "", createdAt: .now, updatedAt: .now)

        expectError(.unauthorized) {
            _ = try configuration.resolve(purpose: .conversation, conversation: conversation, workspace: Workspace(id: workspaceID, name: "Wrong workspace"))
        }
        expectError(.unauthorized) {
            _ = try configuration.resolve(purpose: .conversation, workspace: Workspace(id: workspaceID, name: "Private", allowsRemoteSend: false))
        }

        let anyConnection = Workspace(id: workspaceID, name: "Any", allowedConnectionIDs: nil)
        #expect(try configuration.resolve(purpose: .conversation, workspace: anyConnection).connectionID == fixture.connection.id)
        expectError(.unauthorized) {
            _ = try configuration.resolve(purpose: .conversation, workspace: Workspace(id: workspaceID, name: "None", allowedConnectionIDs: []))
        }
        expectError(.unauthorized) {
            _ = try configuration.resolve(purpose: .conversation, workspace: Workspace(id: workspaceID, name: "Other", allowedConnectionIDs: [ConnectionID()]))
        }
        #expect(try configuration.resolve(purpose: .conversation, workspace: Workspace(id: workspaceID, name: "Allowed", allowedConnectionIDs: [fixture.connection.id])).connectionID == fixture.connection.id)
    }

    @Test func unknownContextOrTextCapabilityBlocksSending() throws {
        let fixture = RoutingFixture()
        let route = makeRoute(name: "Configured", modelDescriptorID: fixture.model.id)
        let binding = RouteBinding(scope: .global, purpose: .conversation, routeID: route.id)
        let unknownContext = ModelDescriptor(id: fixture.model.id, connectionID: fixture.connection.id, connectionRevision: fixture.connection.revision, modelID: "fixture", contextWindow: nil, textCapability: .declared)
        let configuration = ModelConfiguration(connections: [fixture.connection], models: [unknownContext], routes: [route], bindings: [binding])
        expectError(.configuration) { _ = try configuration.resolve(purpose: .conversation) }

        let unknownText = ModelDescriptor(id: fixture.model.id, connectionID: fixture.connection.id, connectionRevision: fixture.connection.revision, modelID: "fixture", contextWindow: 32_768, textCapability: .unknown)
        let capabilityConfiguration = ModelConfiguration(connections: [fixture.connection], models: [unknownText], routes: [route], bindings: [binding])
        expectError(.configuration) { _ = try capabilityConfiguration.resolve(purpose: .conversation) }
    }

    @Test func whitespaceCredentialReferencesAreRejectedBeforeResolutionOrSending() throws {
        let fixture = RoutingFixture()
        var invalidConnection = fixture.connection
        invalidConnection.credentialReference = " \t\n"
        expectError(.configuration) { try invalidConnection.validate() }

        let route = makeRoute(name: "Configured", modelDescriptorID: fixture.model.id)
        let configuration = ModelConfiguration(
            connections: [invalidConnection], models: [fixture.model], routes: [route],
            bindings: [.init(scope: .global, purpose: .conversation, routeID: route.id)]
        )
        expectError(.configuration) { _ = try configuration.resolve(purpose: .conversation) }

        var invalidSnapshot = ResolvedModelRouteSnapshot(
            name: "Configured", providerKind: .openAICompatible, baseURL: fixture.connection.baseURL,
            modelID: "fixture", credentialReference: "fixture", contextWindow: 32_768,
            textCapability: .declared
        )
        invalidSnapshot.credentialReference = " \t\n"
        expectError(.configuration) { try invalidSnapshot.validateForSending() }
    }

    @Test func capabilityObservationFromAnOlderConnectionRevisionIsNotTrusted() throws {
        var connection = ProviderConnection(name: "Rotated connection", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        connection.revision = 2
        let model = ModelDescriptor(connectionID: connection.id, connectionRevision: 1, modelID: "fixture", contextWindow: 32_768, textCapability: .verified, toolCapability: .verified)
        let route = makeRoute(name: "Stale capability", modelDescriptorID: model.id)
        let configuration = ModelConfiguration(connections: [connection], models: [model], routes: [route], bindings: [.init(scope: .global, purpose: .conversation, routeID: route.id)])

        let snapshot = try configuration.snapshot(routeID: route.id)
        #expect(snapshot.textCapability == .unknown)
        #expect(snapshot.toolCapability == .unknown)
        expectError(.configuration) { _ = try configuration.resolve(purpose: .conversation) }
    }

    @Test func resolvedSnapshotKeepsImmutableFieldsAfterConfigurationChanges() throws {
        let fixture = RoutingFixture()
        let route = makeRoute(name: "Frozen", modelDescriptorID: fixture.model.id)
        let configuration = ModelConfiguration(
            connections: [fixture.connection], models: [fixture.model], routes: [route],
            bindings: [.init(scope: .global, purpose: .conversation, routeID: route.id)]
        )
        let snapshot = try configuration.resolve(purpose: .conversation)
        var changedConnection = fixture.connection
        changedConnection.revision += 1
        changedConnection.baseURL = "https://changed.example/v1"
        var changedModel = fixture.model
        changedModel.revision += 1
        changedModel.connectionRevision = changedConnection.revision
        changedModel.modelID = "changed-model"
        var changedRoute = route
        changedRoute.revision += 1
        changedRoute.maxOutputTokens = 2048
        let changed = ModelConfiguration(connections: [changedConnection], models: [changedModel], routes: [changedRoute], bindings: configuration.bindings)

        #expect(try changed.resolve(purpose: .conversation).modelID == "changed-model")
        #expect(snapshot.id == route.id)
        #expect(snapshot.revision == route.revision)
        #expect(snapshot.connectionRevision == fixture.connection.revision)
        #expect(snapshot.baseURL == fixture.connection.baseURL)
        #expect(snapshot.modelID == fixture.model.modelID)
        #expect(snapshot.maxOutputTokens == route.maxOutputTokens)
    }

    @Test func modelPoolShowsOnlyEnabledModelsWithCanonicalRoutesIncludingUnknownCapabilities() throws {
        let connection = ProviderConnection(name: "Provider", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        let model = ModelDescriptor(connectionID: connection.id, modelID: "manual", contextWindow: nil, textCapability: .unknown)
        let disabledModel = ModelDescriptor(connectionID: connection.id, modelID: "disabled", isEnabled: false)
        let canonical = ModelRoute(id: model.poolRouteID, name: "manual", modelDescriptorID: model.id)
        let missingRouteModel = ModelDescriptor(connectionID: connection.id, modelID: "missing")
        let configuration = ModelConfiguration(connections: [connection], models: [model, disabledModel, missingRouteModel], routes: [canonical, ModelRoute(id: disabledModel.poolRouteID, name: "disabled", modelDescriptorID: disabledModel.id)], bindings: [])

        #expect(configuration.modelPool.map(\.id) == [model.id])
        #expect(configuration.modelPool[0].route.id == model.poolRouteID)
        expectError(.configuration) { _ = try configuration.resolve(purpose: .conversation, explicitRouteID: canonical.id) }
    }

    @Test func disabledConnectionAndModelRejectExplicitResolutionWithoutFallback() throws {
        var connection = ProviderConnection(name: "Provider", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture", isEnabled: false)
        var model = ModelDescriptor(connectionID: connection.id, modelID: "manual", contextWindow: 8192, textCapability: .declared)
        let route = ModelRoute(id: model.poolRouteID, name: "manual", modelDescriptorID: model.id)
        let alternative = ProviderConnection(name: "Other", providerKind: .openAICompatible, baseURL: "https://other.invalid/v1", credentialReference: "other")
        let otherModel = ModelDescriptor(connectionID: alternative.id, modelID: "other", contextWindow: 8192, textCapability: .declared)
        let otherRoute = ModelRoute(id: otherModel.poolRouteID, name: "other", modelDescriptorID: otherModel.id)
        let binding = RouteBinding(scope: .global, purpose: .conversation, routeID: otherRoute.id)
        var configuration = ModelConfiguration(connections: [connection, alternative], models: [model, otherModel], routes: [route, otherRoute], bindings: [binding])
        expectError(.configuration) { _ = try configuration.resolve(purpose: .conversation, explicitRouteID: route.id) }
        #expect(try configuration.resolve(purpose: .conversation).id == otherRoute.id)
        #expect(configuration.modelPool.map(\.id) == [otherModel.id])
        connection.isEnabled = true; model.isEnabled = false
        configuration.connections = [connection, alternative]; configuration.models = [model, otherModel]
        expectError(.configuration) { _ = try configuration.resolve(purpose: .conversation, explicitRouteID: route.id) }
        #expect(configuration.modelPool.map(\.id) == [otherModel.id])
    }
}

private struct RoutingFixture {
    let connection: ProviderConnection
    let model: ModelDescriptor

    init() {
        connection = ProviderConnection(name: "Fixture connection", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        model = ModelDescriptor(connectionID: connection.id, connectionRevision: connection.revision, modelID: "fixture", contextWindow: 32_768, textCapability: .declared)
    }
}

private func makeRoute(name: String, modelDescriptorID: ModelDescriptorID) -> ModelRoute {
    .init(name: name, modelDescriptorID: modelDescriptorID, maxOutputTokens: 1024)
}

private func expectError(_ code: MiraError.Code, _ operation: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try operation()
        Issue.record("Expected MiraError.\(code.rawValue).", sourceLocation: sourceLocation)
    } catch let error as MiraError {
        #expect(error.code == code, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected MiraError.\(code.rawValue), received a different error.", sourceLocation: sourceLocation)
    }
}
