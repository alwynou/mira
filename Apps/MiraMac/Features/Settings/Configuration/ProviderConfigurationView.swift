import SwiftUI
import MiraCore

/// The model library editor. Connections, model descriptors, routes, and bindings are
/// separate records so changing one does not silently rewrite the others.
struct ProviderConfigurationView: View {
    @Environment(\.locale) private var locale
    let container: AppContainer

    @State private var configuration = ModelConfiguration(connections: [], models: [], routes: [], bindings: [])
    @State private var workspaces: [Workspace] = []
    @State private var conversations: [Conversation] = []
    @State private var selectedConnection: ConnectionID?
    @State private var selectedModel: ModelDescriptorID?
    @State private var selectedRoute: RouteID?
    @State private var editingConnection: ProviderConnection?
    @State private var editingModel: ModelDescriptor?
    @State private var editingRoute: ModelRoute?
    @State private var showingConnectionEditor = false
    @State private var showingModelEditor = false
    @State private var showingRouteEditor = false
    @State private var statusKey: String?
    @State private var error: MiraError?
    @State private var isWorking = false
    @State private var probeTask: Task<Void, Never>?
    @State private var section: ConfigurationPane = .connections

    var body: some View {
        VStack(spacing: 14) {
            Picker("Configuration section", selection: $section) {
                Text("Connections").tag(ConfigurationPane.connections)
                Text("Models").tag(ConfigurationPane.models)
                Text("Routes").tag(ConfigurationPane.routes)
                Text("Purpose Routing").tag(ConfigurationPane.purposeRouting)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Configuration section")
            Group {
                switch section {
                case .connections: connectionsSection
                case .models: modelsSection
                case .routes: routesSection
                case .purposeRouting:
                    PurposeRoutingView(configuration: configuration, workspaces: workspaces, conversations: conversations, container: container, onChange: { await refresh() })
                }
            }
        }
        .padding(20)
        .task { await observeLibrary() }
        .onDisappear { probeTask?.cancel() }
        .sheet(isPresented: $showingConnectionEditor) {
            ConnectionEditor(existing: editingConnection, container: container, onSaved: { await refresh() })
                .environment(\.locale, locale)
        }
        .sheet(isPresented: $showingModelEditor) {
            ModelDescriptorEditor(existing: editingModel, connections: configuration.connections, container: container, onSaved: { await refresh() })
                .environment(\.locale, locale)
        }
        .sheet(isPresented: $showingRouteEditor) {
            ModelRouteEditor(existing: editingRoute, models: configuration.models, connections: configuration.connections, container: container, onSaved: { await refresh() })
                .environment(\.locale, locale)
        }
    }

    private enum ConfigurationPane: Hashable {
        case connections, models, routes, purposeRouting
    }

    private var connectionsSection: some View {
        ConfigurationSection(title: "Connections", subtitle: "Provider endpoints and Keychain credential references are shared by model descriptors.") {
            List(selection: $selectedConnection) {
                ForEach(configuration.connections) { connection in
                    HStack {
                        Image(systemName: "network")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: connection.name).font(.headline)
                            Text(providerName(connection.providerKind)).font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: connection.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(LocalizedStringKey(connection.credentialReference.isEmpty ? "No API key" : "Keychain credential"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(connection.id)
                }
            }
            .overlay { if configuration.connections.isEmpty { ContentUnavailableView("No Connections", systemImage: "network.slash", description: Text("Add a provider connection to describe a model.")) } }
            configurationActions {
                Button("Add Connection", systemImage: "plus") { editingConnection = nil; showingConnectionEditor = true }
                Button("Edit") { editingConnection = selectedConnection.flatMap { id in configuration.connections.first { $0.id == id } }; showingConnectionEditor = true }.disabled(selectedConnection == nil)
                Button("Remove", role: .destructive) { removeConnection() }.disabled(selectedConnection == nil || container.isDemo)
            }
            Text("Removing a connection also removes its model descriptors, routes, and purpose bindings.")
                .font(.caption).foregroundStyle(.secondary)
            statusView
        }
    }

    private var modelsSection: some View {
        ConfigurationSection(title: "Models", subtitle: "A model descriptor selects a connection and records declared or probed capabilities.") {
            List(selection: $selectedModel) {
                ForEach(configuration.models) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: model.modelID).font(.headline)
                            connectionNameView(model.connectionID).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            capabilityLabel("Text", state: model.textCapability)
                            capabilityLabel("Tools", state: model.toolCapability)
                            if let window = model.contextWindow { Text(L10n.format("Context window: %@ tokens", locale: locale, String(window))) }
                            else { Text("Context window unknown") }
                            if configuration.connections.first(where: { $0.id == model.connectionID })?.revision != model.connectionRevision {
                                Text("Needs reconfirmation").foregroundStyle(.orange)
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(model.id)
                }
            }
            .overlay { if configuration.models.isEmpty { ContentUnavailableView("No Models", systemImage: "cube.transparent", description: Text("Add a model descriptor after creating a connection.")) } }
            configurationActions {
                Button("Add Model", systemImage: "plus") { editingModel = nil; showingModelEditor = true }
                    .disabled(configuration.connections.isEmpty)
                Button("Edit") { editingModel = selectedModel.flatMap { id in configuration.models.first { $0.id == id } }; showingModelEditor = true }.disabled(selectedModel == nil)
                Button("Remove", role: .destructive) { removeModel() }.disabled(selectedModel == nil || container.isDemo)
            }
            statusView
        }
    }

    private var routesSection: some View {
        ConfigurationSection(title: "Routes", subtitle: "Named presets hold output limits and usage reporting. Assign them to purposes in Purpose Routing.") {
            List(selection: $selectedRoute) {
                ForEach(configuration.routes) { route in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: route.name).font(.headline)
                        modelNameView(route.modelDescriptorID).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Text(L10n.format("Maximum output: %@ tokens", locale: locale, String(route.maxOutputTokens)))
                            Text(LocalizedStringKey(route.requestsUsage ? "Usage reporting on" : "Usage reporting off"))
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(route.id)
                }
            }
            .overlay { if configuration.routes.isEmpty { ContentUnavailableView("No Routes", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Create a named route preset to use a model.")) } }
            configurationActions {
                Button("Add Route", systemImage: "plus") { editingRoute = nil; showingRouteEditor = true }.disabled(configuration.models.isEmpty)
                Button("Edit") { editingRoute = selectedRoute.flatMap { id in configuration.routes.first { $0.id == id } }; showingRouteEditor = true }.disabled(selectedRoute == nil)
                Button("Test Text") { runProbe(.text) }.disabled(selectedRoute == nil || isWorking || container.isDemo)
                Button("Test Tools") { runProbe(.tools) }.disabled(selectedRoute == nil || isWorking || container.isDemo)
                if probeTask != nil { Button("Cancel Test") { probeTask?.cancel() } }
                Button("Remove", role: .destructive) { removeRoute() }.disabled(selectedRoute == nil || container.isDemo)
            }
            Text("Capability tests send a fixed synthetic prompt without conversation history. Your provider may charge a small API fee.")
                .font(.caption).foregroundStyle(.secondary)
            if let route = selectedRoute.flatMap({ id in configuration.routes.first { $0.id == id } }), let model = configuration.models.first(where: { $0.id == route.modelDescriptorID }), let observation = model.probeObservation {
                LabeledContent(LocalizedStringKey(observation.type == .text ? "Latest Text Test" : "Latest Tool Test")) {
                    Text(LocalizedStringKey(observation.state == .verified ? "Passed" : "Failed"))
                    Text(observation.checkedAt, format: .dateTime)
                }.font(.caption).foregroundStyle(observation.state == .verified ? .green : .orange)
            }
            statusView
        }
    }

    @ViewBuilder private var statusView: some View {
        if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        if let statusKey { Text(L10n.string(statusKey, locale: locale)).font(.callout).foregroundStyle(.secondary) }
        if container.isDemo { Text("Demo mode: configuration changes and capability tests are disabled.").font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func configurationActions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { content(); Spacer() }.buttonStyle(.bordered)
    }

    private func providerName(_ kind: ProviderKind) -> LocalizedStringKey {
        LocalizedStringKey(kind == .anthropic ? "Anthropic Messages" : "OpenAI Chat Completions Compatible")
    }
    @ViewBuilder private func connectionNameView(_ id: ConnectionID) -> some View {
        if let name = configuration.connections.first(where: { $0.id == id })?.name { Text(verbatim: name) }
        else { Text("Missing connection") }
    }
    @ViewBuilder private func modelNameView(_ id: ModelDescriptorID) -> some View {
        if let modelID = configuration.models.first(where: { $0.id == id })?.modelID { Text(verbatim: modelID) }
        else { Text("Missing model") }
    }
    private func capabilityLabel(_ label: LocalizedStringKey, state: CapabilityState) -> some View { Label(label, systemImage: capabilityIcon(state)) }
    private func capabilityIcon(_ state: CapabilityState) -> String { switch state { case .unknown: "questionmark.circle"; case .declared: "checkmark.circle"; case .verified: "checkmark.seal"; case .failed: "xmark.circle" } } // i18n-verbatim: SF Symbols identifiers.

    private func observeLibrary() async {
        guard let application = container.application else { return }
        await refresh()
        for await _ in await application.events() {
            if Task.isCancelled { return }
            await refresh()
        }
    }

    private func refresh() async {
        guard let application = container.application else { return }
        do {
            let library = try await application.library(includeArchived: true)
            configuration = library.configuration
            workspaces = library.workspaces
            conversations = library.conversations
        } catch { self.error = MiraError.safe(error) }
    }

    private func removeConnection() {
        guard let id = selectedConnection, let connection = configuration.connections.first(where: { $0.id == id }) else { return }
        Task { @MainActor in
            do { try await container.removeConnection(connection); selectedConnection = nil; statusKey = "Connection removed." }
            catch { self.error = MiraError.safe(error) }
        }
    }
    private func removeModel() {
        guard let id = selectedModel, let application = container.application else { return }
        Task { @MainActor in
            do { try await application.removeModel(id); selectedModel = nil; statusKey = "Model removed." }
            catch { self.error = MiraError.safe(error) }
        }
    }
    private func removeRoute() {
        guard let id = selectedRoute, let application = container.application else { return }
        Task { @MainActor in
            do { try await application.removeRoute(id); selectedRoute = nil; statusKey = "Route removed." }
            catch { self.error = MiraError.safe(error) }
        }
    }
    private func runProbe(_ kind: CapabilityProbeKind) {
        guard !container.isDemo, let routeID = selectedRoute else { return }
        do {
            let snapshot = try configuration.snapshot(routeID: routeID, purpose: .conversation, selection: .explicit)
            isWorking = true; error = nil; statusKey = "Testing with synthetic content only, without conversation history…"
            probeTask = Task { @MainActor in
                let observation = await container.probe(snapshot, kind: kind)
                defer { isWorking = false; probeTask = nil }
                guard !Task.isCancelled else { statusKey = "Test cancelled. Capability status was not changed."; return }
                guard observation.state != .unknown else { error = observation.error ?? MiraError(.configuration, "Capability test failed."); return }
                do { try await container.saveProbe(observation, for: snapshot); statusKey = observation.state == .verified ? "Capability test passed and was saved." : "Capability test failed; status was recorded." }
                catch { self.error = MiraError.safe(error) }
            }
        } catch { self.error = MiraError.safe(error) }
    }
}

private struct ConfigurationSection<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let content: Content
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.title = title; self.subtitle = subtitle; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content
        }.padding(.top, 12)
    }
}

private struct ConnectionEditor: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let existing: ProviderConnection?
    let container: AppContainer
    let onSaved: () async -> Void
    @State private var name = ""
    @State private var kind = ProviderKind.openAICompatible
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var credentialReference = ""
    @State private var credentialVersion = 1
    @State private var secret = ""
    @State private var allowsHTTP = false
    @State private var error: MiraError?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(existing == nil ? "Add Connection" : "Edit Connection")).font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                Picker("Protocol", selection: Binding(get: { kind }, set: { newValue in kind = newValue; if existing == nil { baseURL = newValue == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1" } })) {
                    Text("OpenAI Chat Completions Compatible").tag(ProviderKind.openAICompatible)
                    Text("Anthropic Messages").tag(ProviderKind.anthropic)
                }
                TextField("Base URL", text: $baseURL)
                SecureField(LocalizedStringKey(existing == nil ? "API Key" : "New API Key (leave blank to keep)"), text: $secret)
                Toggle("Allow explicitly configured local HTTP services", isOn: $allowsHTTP)
            }
            Text("Use a base service URL without credentials, query parameters, fragments, or a provider route suffix. API keys are stored in this Mac’s Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel", role: .cancel) { secret = ""; dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || container.isDemo) }
        }
        .padding(28).frame(width: 590)
        .onAppear { load() }
    }
    private func load() {
        guard let existing else { return }
        name = existing.name; kind = existing.providerKind; baseURL = existing.baseURL
        credentialReference = existing.credentialReference; credentialVersion = existing.credentialVersion; allowsHTTP = existing.allowsLoopbackHTTP
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            let connection = ProviderConnection(id: existing?.id ?? .init(), revision: existing.map { $0.revision + 1 } ?? 1, name: name.trimmingCharacters(in: .whitespacesAndNewlines), providerKind: kind, baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), credentialReference: credentialReference.isEmpty ? UUID().uuidString : credentialReference, credentialVersion: credentialVersion, allowsLoopbackHTTP: allowsHTTP)
            try connection.validate()
            try await container.saveConnection(connection, previous: existing, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
            secret = ""; await onSaved(); dismiss()
        } catch { self.error = MiraError.safe(error) }
    }
}

private struct ModelDescriptorEditor: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let existing: ModelDescriptor?
    let connections: [ProviderConnection]
    let container: AppContainer
    let onSaved: () async -> Void
    @State private var connectionID: ConnectionID?
    @State private var modelID = ""
    @State private var contextWindow = ""
    @State private var textDeclared = false
    @State private var toolsDeclared = false
    @State private var error: MiraError?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(existing == nil ? "Add Model" : "Edit Model")).font(.title2.weight(.semibold))
            Form {
                Picker("Connection", selection: Binding(get: { connectionID }, set: { connectionID = $0 })) {
                    Text("Select a connection").tag(nil as ConnectionID?)
                    ForEach(connections) { connection in Text(verbatim: connection.name).tag(Optional(connection.id)) }
                }
                TextField("Model ID", text: $modelID)
                TextField("Context Window (tokens, optional)", text: $contextWindow)
                Toggle("Text capability declared", isOn: $textDeclared)
                Toggle("Tool capability declared", isOn: $toolsDeclared)
            }
            Text("Declare capabilities only when you have verified them. Capability observations reset when the connection, model ID, or context window changes. Unknown text capability can still be tested from Routes.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || connectionID == nil || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || container.isDemo) }
        }
        .padding(28).frame(width: 590)
        .onAppear { load() }
    }
    private func load() {
        guard let existing else { connectionID = connections.first?.id; return }
        connectionID = existing.connectionID; modelID = existing.modelID; contextWindow = existing.contextWindow.map(String.init) ?? ""
        textDeclared = existing.textCapability == .declared || existing.textCapability == .verified
        toolsDeclared = existing.toolCapability == .declared || existing.toolCapability == .verified
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            guard let connectionID else { throw MiraError(.configuration, "Select a provider connection first.") }
            let window = contextWindow.trimmingCharacters(in: .whitespacesAndNewlines)
            guard window.isEmpty || (Int(window).map { $0 > 0 && $0 <= 10_000_000 } ?? false) else { throw MiraError(.configuration, "Enter a valid context window, or leave it unknown.") }
            let parsedWindow = Int(window)
            guard let connection = connections.first(where: { $0.id == connectionID }) else { throw MiraError(.configuration, "The selected provider connection no longer exists.") }
            let descriptorChanged = existing.map { $0.connectionID != connectionID || $0.connectionRevision != connection.revision || $0.modelID != modelID.trimmingCharacters(in: .whitespacesAndNewlines) || $0.contextWindow != parsedWindow } ?? true
            let textDeclarationChanged = existing.map { ($0.textCapability == .declared || $0.textCapability == .verified) != textDeclared } ?? true
            let toolsDeclarationChanged = existing.map { ($0.toolCapability == .declared || $0.toolCapability == .verified) != toolsDeclared } ?? true
            let textCapability: CapabilityState = if !descriptorChanged, let previous = existing, previous.textCapability == .verified, textDeclared { .verified } else if !descriptorChanged, let previous = existing, previous.textCapability == .failed, !textDeclared { .failed } else { textDeclared ? .declared : .unknown }
            let toolCapability: CapabilityState = if !descriptorChanged, let previous = existing, previous.toolCapability == .verified, toolsDeclared { .verified } else if !descriptorChanged, let previous = existing, previous.toolCapability == .failed, !toolsDeclared { .failed } else { toolsDeclared ? .declared : .unknown }
            let observation = descriptorChanged || textDeclarationChanged || toolsDeclarationChanged ? nil : existing?.probeObservation
            let model = ModelDescriptor(id: existing?.id ?? .init(), revision: existing.map { $0.revision + 1 } ?? 1, connectionID: connectionID, connectionRevision: connection.revision, modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines), contextWindow: parsedWindow, textCapability: textCapability, toolCapability: toolCapability, probeObservation: observation)
            try model.validate()
            guard let application = container.application else { throw MiraError(.storage, "The library is not open.") }
            try await application.saveModel(model, expectedRevision: existing?.revision)
            await onSaved(); dismiss()
        } catch { self.error = MiraError.safe(error) }
    }
}

private struct ModelRouteEditor: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let existing: ModelRoute?
    let models: [ModelDescriptor]
    let connections: [ProviderConnection]
    let container: AppContainer
    let onSaved: () async -> Void
    @State private var name = ""
    @State private var modelID: ModelDescriptorID?
    @State private var maxOutputTokens = "1024"
    @State private var requestsUsage = true
    @State private var error: MiraError?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(existing == nil ? "Add Route" : "Edit Route")).font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                Picker("Model", selection: Binding(get: { modelID }, set: { modelID = $0 })) {
                    Text("Select a model").tag(nil as ModelDescriptorID?)
                    ForEach(models) { model in
                        Text(verbatim: modelOptionLabel(model)).tag(Optional(model.id))
                    }
                }
                TextField("Maximum Output Tokens", text: $maxOutputTokens)
                Toggle("Request streaming token usage when supported", isOn: $requestsUsage)
            }
            Text("A route is a reusable preset. Assign it to a purpose and scope explicitly in Purpose Routing.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || modelID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || container.isDemo) }
        }
        .padding(28).frame(width: 590)
        .onAppear { load() }
    }
    private func load() { guard let existing else { return }; name = existing.name; modelID = existing.modelDescriptorID; maxOutputTokens = String(existing.maxOutputTokens); requestsUsage = existing.requestsUsage }
    private func modelOptionLabel(_ model: ModelDescriptor) -> String {
        guard let connection = connections.first(where: { $0.id == model.connectionID }) else { return model.modelID }
        return "\(model.modelID) — \(connection.name)"
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            guard let modelID, let output = Int(maxOutputTokens.trimmingCharacters(in: .whitespacesAndNewlines)), output > 0 else { throw MiraError(.configuration, "Enter a valid maximum output token count and select a model.") }
            if let contextWindow = models.first(where: { $0.id == modelID })?.contextWindow, output >= contextWindow {
                throw MiraError(.configuration, "Maximum output tokens must be smaller than the model context window.")
            }
            let route = ModelRoute(id: existing?.id ?? .init(), revision: existing.map { $0.revision + 1 } ?? 1, name: name.trimmingCharacters(in: .whitespacesAndNewlines), modelDescriptorID: modelID, maxOutputTokens: output, requestsUsage: requestsUsage)
            try route.validate()
            guard let application = container.application else { throw MiraError(.storage, "The library is not open.") }
            try await application.saveRoute(route, expectedRevision: existing?.revision)
            await onSaved(); dismiss()
        } catch { self.error = MiraError.safe(error) }
    }
}

private enum RoutingScopeChoice: Hashable { case global; case workspace(WorkspaceID); case conversation(ConversationID) }

private struct PurposeRoutingView: View {
    @Environment(\.locale) private var locale
    let configuration: ModelConfiguration
    let workspaces: [Workspace]
    let conversations: [Conversation]
    let container: AppContainer
    let onChange: () async -> Void
    @State private var purpose = ModelPurpose.conversation
    @State private var scope: RoutingScopeChoice = .global
    @State private var routeID: RouteID?
    @State private var loadedBinding: RouteBinding?
    @State private var error: MiraError?
    @State private var statusKey: String?
    @State private var saving = false

    var body: some View {
        ConfigurationSection(title: "Purpose Routing", subtitle: "Choose a route for each purpose and scope. Leaving a scope unbound inherits from its parent resolution or reports that no route is configured.") {
            Form {
                Picker("Purpose", selection: $purpose) {
                    Text("Conversation").tag(ModelPurpose.conversation)
                    Text("Memory Extraction").tag(ModelPurpose.memoryExtraction)
                }
                Picker("Scope", selection: $scope) {
                    Text("Global").tag(RoutingScopeChoice.global)
                    if !workspaces.isEmpty {
                        Section("Workspaces") { ForEach(workspaces) { Text(verbatim: $0.name).tag(RoutingScopeChoice.workspace($0.id)) } }
                    }
                    if !conversations.isEmpty {
                        Section("Conversations") { ForEach(conversations) { conversationLabelView($0).tag(RoutingScopeChoice.conversation($0.id)) } }
                    }
                }
                Picker("Route", selection: Binding(get: { routeID }, set: { routeID = $0 })) {
                    Text("Inherit / no binding").tag(nil as RouteID?)
                    ForEach(configuration.routes) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
            }.formStyle(.grouped).disabled(saving)
            HStack {
                Button("Save Binding") { saveBinding() }.buttonStyle(.borderedProminent).disabled(saving || container.isDemo || (routeID == nil && loadedBinding == nil))
                Button("Remove Binding / Inherit", role: .destructive) { removeBinding() }.disabled(saving || container.isDemo || loadedBinding == nil)
            }
            Text("A route is never created automatically. Removing a local binding lets resolution continue to the workspace or global binding when one exists.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red) }
            if let statusKey { Text(L10n.string(statusKey, locale: locale)).font(.callout).foregroundStyle(.secondary) }
            if container.isDemo { Text("Demo mode: configuration changes are disabled.").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { loadBinding() }
        .onChange(of: purpose) { _, _ in loadBinding() }
        .onChange(of: scope) { _, _ in loadBinding() }
    }

    private var currentRouteScope: RouteScope { switch scope { case .global: .global; case .workspace(let id): .workspace(id); case .conversation(let id): .conversation(id) } }
    private var currentBinding: RouteBinding? { configuration.bindings.first { $0.scope == currentRouteScope && $0.purpose == purpose } }
    private func loadBinding() {
        loadedBinding = currentBinding
        routeID = loadedBinding?.routeID
        error = nil
        statusKey = nil
    }
    @ViewBuilder private func conversationLabelView(_ conversation: Conversation) -> some View {
        if conversation.title.isEmpty { Text("Untitled conversation") }
        else { Text(verbatim: conversation.title) }
    }
    private func saveBinding() {
        guard let application = container.application else { return }
        let targetScope = currentRouteScope
        let targetPurpose = purpose
        let selectedRouteID = routeID
        let expectedRevision = loadedBinding?.revision
        saving = true
        error = nil
        Task { @MainActor in
            do {
                if let selectedRouteID {
                    let binding = RouteBinding(scope: targetScope, purpose: targetPurpose, routeID: selectedRouteID, revision: (expectedRevision ?? 0) + 1)
                    try await application.saveRouteBinding(binding, expectedRevision: expectedRevision)
                    loadedBinding = binding
                    routeID = selectedRouteID
                    statusKey = "Binding saved."
                } else if let loadedBinding {
                    try await application.removeRouteBinding(loadedBinding)
                    self.loadedBinding = nil
                    routeID = nil
                    statusKey = "Binding removed; using inherited routing."
                }
                saving = false
                await onChange()
            } catch { saving = false; self.error = MiraError.safe(error) }
        }
    }
    private func removeBinding() {
        guard let binding = loadedBinding, let application = container.application else { routeID = nil; return }
        saving = true
        error = nil
        Task { @MainActor in
            do {
                try await application.removeRouteBinding(binding)
                loadedBinding = nil
                routeID = nil
                saving = false
                statusKey = "Binding removed; using inherited routing."
                await onChange()
            }
            catch { saving = false; self.error = MiraError.safe(error) }
        }
    }
}
