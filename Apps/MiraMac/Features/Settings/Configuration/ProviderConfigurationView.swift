import SwiftUI
import MiraCore

struct ProviderConfigurationView: View {
    @Environment(\.locale) private var locale
    @State private var model: ProviderLibraryModel
    @State private var section = ConfigurationPane.providers
    @State private var editingConnection: ProviderConnection?
    @State private var showingConnectionEditor = false
    @State private var modelEditor: ModelEditorSelection?
    @State private var removal: RemovalSelection?
    @State private var search = ""
    @State private var providerSearch = ""
    @State private var useFilter: ModelSelectionUse?

    init(container: AppContainer) { _model = State(initialValue: ProviderLibraryModel(container: container)) }

    private enum ConfigurationPane: Hashable { case providers, pool, defaults }
    private struct ModelEditorSelection: Identifiable {
        let id = UUID()
        let connection: ProviderConnection
        let existing: ModelDescriptor?
        let route: ModelRoute?
        let initialModelID: String
    }
    private enum RemovalSelection { case provider(ProviderConnection), model(ModelDescriptor) }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Configuration section", selection: $section) {
                Text("Providers").tag(ConfigurationPane.providers)
                Text("Model Pool").tag(ConfigurationPane.pool)
                Text("Default Models").tag(ConfigurationPane.defaults)
            }.pickerStyle(.segmented)
            switch section {
            case .providers: providers
            case .pool: pool
            case .defaults:
                PurposeRoutingView(configuration: model.configuration, workspaces: model.workspaces,
                                   conversations: model.conversations, container: model.container, onChange: { await model.refresh() })
            }
            status
        }
        .padding(16)
        .task { await model.observe() }
        .onChange(of: model.selectedConnectionID) { _, _ in providerSearch = "" }
        .onDisappear { model.stopRequests() }
        .sheet(isPresented: $showingConnectionEditor) {
            ProviderConnectionEditor(existing: editingConnection, container: model.container) { id in
                await model.refresh(); model.selectedConnectionID = id
            }.environment(\.locale, locale)
        }
        .sheet(item: $modelEditor) { selection in
            PoolModelEditor(existing: selection.existing, connection: selection.connection, route: selection.route,
                            initialModelID: selection.initialModelID, container: model.container,
                            onSaved: { await model.refresh() })
                .environment(\.locale, locale)
        }
        .confirmationDialog("Remove configuration?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                let target = removal; removal = nil
                Task {
                    switch target {
                    case .provider(let connection): await model.removeProvider(connection)
                    case .model(let descriptor): await model.removeModel(descriptor)
                    case nil: break
                    }
                }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Removal also deletes the related model presets and default selections. Disable the item to keep its configuration.")
        }
    }

    private var providers: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Providers").font(.title2.weight(.semibold))
                List(selection: $model.selectedConnectionID) {
                    ForEach(model.configuration.connections) { connection in
                        HStack {
                            Image(systemName: connection.isEnabled ? "circle.fill" : "circle")
                                .foregroundStyle(connection.isEnabled ? Color.green : Color.secondary)
                                .font(.caption2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: connection.name).font(.headline)
                                Text(LocalizedStringKey(connection.isEnabled ? "Active" : "Inactive")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4).tag(connection.id)
                    }
                }.overlay {
                    if model.configuration.connections.isEmpty { Text("Add a provider to get started.").foregroundStyle(.secondary).padding() }
                }
                Button("Add Provider", systemImage: "plus") { editingConnection = nil; showingConnectionEditor = true }
                    .disabled(model.isWorking || model.container.isDemo)
            }.frame(width: 205)
            Divider()
            if let connection = model.selectedConnection { providerDetail(connection) }
            else {
                ContentUnavailableView("Connect a Provider", systemImage: "network",
                                       description: Text("Configure and activate a provider, select its models, then choose a model from your pool."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func providerDetail(_ connection: ProviderConnection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: connection.name).font(.title2.weight(.semibold))
                    Text(verbatim: connection.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Toggle("Active", isOn: Binding(get: { connection.isEnabled }, set: { enabled in
                    Task { await model.setProviderEnabled(enabled, connection: connection) }
                })).toggleStyle(.switch).fixedSize().disabled(model.isWorking || model.container.isDemo)
            }
            HStack {
                Button("Edit Provider") { model.cancelProbe(); editingConnection = connection; showingConnectionEditor = true }
                Button("Remove", role: .destructive) { removal = .provider(connection) }
            }.disabled(model.isWorking || model.container.isDemo)
            Text("Activation allows explicit model requests. It does not verify connectivity or enable any models automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if connection.isEnabled {
                HStack {
                    Text("Provider Models").font(.headline)
                    Spacer()
                    if model.isDiscovering {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelDiscovery() }
                    } else {
                        Button("Fetch Models", systemImage: "arrow.clockwise") { model.discoverModels() }
                    }
                    Button("Add Manually", systemImage: "plus") { editModel(nil, connection: connection) }
                }.disabled(model.isWorking || model.container.isDemo)
                Text("Fetching reads only this provider’s model catalog. You can add a private deployment ID manually if discovery is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Activate this provider to fetch or add models.", systemImage: "pause.circle").font(.callout)
            }
            TextField("Search provider models", text: $providerSearch).textFieldStyle(.roundedBorder)
            Text("The bundled catalog supplies model information, not account access. Fetch Models checks the provider list; catalog entries may be unavailable for your account.")
                .font(.caption).foregroundStyle(.secondary)
            providerModelList(connection)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerModelList(_ connection: ProviderConnection) -> some View {
        List {
            if !model.providerModels.isEmpty {
                Section("Saved Models") {
                    ForEach(model.providerModels.filter { matchesProviderSearch($0.modelID) }) { descriptor in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: descriptor.modelID).font(.headline)
                                modelReadiness(descriptor)
                            }
                            Spacer()
                            Button("Configure") { editModel(descriptor, connection: connection) }
                                .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                            Toggle("In Model Pool", isOn: Binding(get: { descriptor.isEnabled }, set: { enabled in
                                Task { await model.setModelEnabled(enabled, model: descriptor) }
                            })).labelsHidden()
                                .accessibilityLabel(Text(L10n.format("Include %@ in Model Pool", locale: locale, descriptor.modelID)))
                                .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                        }.padding(.vertical, 3)
                            .contextMenu {
                                Button("Remove", role: .destructive) { removal = .model(descriptor) }
                                    .disabled(model.isWorking || model.container.isDemo)
                            }
                    }
                }
            }
            if !model.newDiscoveredModels.isEmpty {
                Section("Available from Provider") {
                    ForEach(model.newDiscoveredModels.filter { matchesProviderSearch($0.id, name: $0.displayName) }) { discovered in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: discovered.id)
                                if let name = discovered.displayName, name != discovered.id { Text(verbatim: name).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Add to Pool") { editModel(nil, connection: connection, modelID: discovered.id) }
                                .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                        }
                    }
                }
            }
            if !model.newCatalogModels.isEmpty {
                Section("Bundled Catalog · models.dev") {
                    ForEach(model.newCatalogModels.filter { matchesProviderSearch($0.id, name: $0.metadata.displayName) }) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: item.metadata.displayName ?? item.id)
                                Text(verbatim: item.id).font(.caption).foregroundStyle(.secondary)
                                if item.suggestedProtocolMode == .unsupportedReasoning {
                                    Text("Reasoning continuation is not supported yet").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button("Add to Pool") { editModel(nil, connection: connection, modelID: item.id) }
                                .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                        }
                    }
                }
            }
        }.overlay {
            if model.providerModels.isEmpty && model.newDiscoveredModels.isEmpty && model.newCatalogModels.isEmpty {
                ContentUnavailableView("No Models Selected", systemImage: "cube.transparent",
                                       description: Text("Fetch the model list or add a Model ID manually, then configure the models you want to use."))
            }
        }
    }

    private var pool: some View {
        ConfigurationSection(title: "Model Pool", subtitle: "Manage enabled models here. Model selectors show only models ready for their purpose; use the filters to check readiness.") {
            TextField("Search models or providers", text: $search)
                .textFieldStyle(.roundedBorder)
            Picker("Filter by use", selection: $useFilter) {
                Text("All Models").tag(nil as ModelSelectionUse?)
                Text("Conversation").tag(Optional(ModelSelectionUse.conversation))
                Text("Agent Tools").tag(Optional(ModelSelectionUse.agentTools))
                Text("Memory Extraction").tag(Optional(ModelSelectionUse.memoryExtraction))
            }.pickerStyle(.segmented)
            List {
                ForEach(filteredPool) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: entry.model.modelID).font(.headline)
                                Text(verbatim: entry.connection.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Configure") { editModel(entry.model, connection: entry.connection) }
                            Button("Disable") { Task { await model.setModelEnabled(false, model: entry.model) } }
                            Button("Remove", role: .destructive) { removal = .model(entry.model) }
                        }
                        modelReadiness(entry.model)
                        HStack {
                            Button("Test Text") { model.probe(entry.model, kind: .text) }
                            Button("Test Tools") { model.probe(entry.model, kind: .tools) }
                            Button("Test JSON Extraction") { model.probe(entry.model, kind: .jsonExtraction) }
                        }.disabled(model.isProbing)
                    }.padding(.vertical, 6).disabled(model.isWorking || model.container.isDemo)
                }
            }.overlay {
                if filteredPool.isEmpty {
                    ContentUnavailableView("No Matching Models", systemImage: "square.stack.3d.up",
                                           description: Text("Clear the search or filter, or configure model capabilities under All Models. Only active providers contribute to the pool."))
                }
            }
            HStack {
                Button("Manage Providers") { section = .providers }
                Button("Choose Default Models") { section = .defaults }.disabled(model.configuration.modelPool.isEmpty)
                if model.isProbing { ProgressView().controlSize(.small); Button("Cancel Test") { model.cancelProbe() } }
            }
            Text("Capability tests send a fixed synthetic prompt without conversation history. Your provider may charge for the request.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var filteredPool: [ModelPoolEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = useFilter.map { model.configuration.models(for: $0) } ?? model.configuration.modelPool
        return candidates.filter { query.isEmpty || $0.model.modelID.localizedStandardContains(query) || $0.connection.name.localizedStandardContains(query) }
    }

    private func matchesProviderSearch(_ id: String, name: String? = nil) -> Bool {
        let query = providerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || id.localizedStandardContains(query) || name?.localizedStandardContains(query) == true
    }

    @ViewBuilder private func modelReadiness(_ descriptor: ModelDescriptor) -> some View {
        HStack(spacing: 10) {
            Label("Text", systemImage: capabilityIcon(descriptor.textCapability))
                .accessibilityValue(L10n.string(capabilityTitle(descriptor.textCapability), locale: locale))
            Label("Tools", systemImage: capabilityIcon(descriptor.toolCapability))
                .accessibilityValue(L10n.string(capabilityTitle(descriptor.toolCapability), locale: locale))
            Label("JSON Extraction", systemImage: capabilityIcon(descriptor.extractionCapability))
                .accessibilityValue(L10n.string(capabilityTitle(descriptor.extractionCapability), locale: locale))
        }.font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 10) {
            if let window = descriptor.contextWindow { Text(L10n.format("Context window: %@ tokens", locale: locale, String(window))) }
            else { Text("Context window unknown") }
            if model.configuration.connections.first(where: { $0.id == descriptor.connectionID })?.revision != descriptor.connectionRevision {
                Text("Needs reconfirmation").foregroundStyle(.orange)
            }
        }.font(.caption).foregroundStyle(.secondary)
        if let snapshot = try? model.configuration.snapshot(routeID: descriptor.poolRouteID),
           let reason = readinessError(snapshot) {
            Text(L10n.error(reason, locale: locale)).font(.caption).foregroundStyle(.orange)
        }
    }

    private func readinessError(_ snapshot: ResolvedModelRouteSnapshot) -> MiraError? {
        do { try snapshot.validateForSending(); return nil }
        catch { return MiraError.safe(error) }
    }

    private func capabilityTitle(_ state: CapabilityState) -> String {
        switch state {
        case .unknown: "Unknown"
        case .declared: "Declared"
        case .verified: "Verified"
        case .failed: "Failed"
        }
    }

    private func capabilityIcon(_ state: CapabilityState) -> String {
        switch state { case .unknown: "questionmark.circle"; case .declared: "checkmark.circle"; case .verified: "checkmark.seal"; case .failed: "xmark.circle" } // i18n-verbatim: SF Symbols identifiers.
    }

    private func editModel(_ descriptor: ModelDescriptor?, connection: ProviderConnection, modelID: String = "") {
        model.cancelProbe()
        let route = descriptor.flatMap { item in model.configuration.routes.first { $0.id == item.poolRouteID } }
        modelEditor = ModelEditorSelection(connection: connection, existing: descriptor, route: route, initialModelID: modelID)
    }

    @ViewBuilder private var status: some View {
        if let error = model.error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        else if let key = model.statusKey { Text(L10n.string(key, locale: locale)).font(.callout).foregroundStyle(.secondary) }
        if model.container.isDemo { Text("Demo mode: configuration changes are disabled.").font(.caption).foregroundStyle(.secondary) }
    }
}

struct ConfigurationSection<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let content: Content
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
