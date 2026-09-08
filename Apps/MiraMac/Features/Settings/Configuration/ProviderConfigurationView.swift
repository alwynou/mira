import SwiftUI
import MiraCore
import MiraProviders

struct ProviderConfigurationView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: ProviderLibraryModel
    let destination: SettingsDestination
    let navigate: (SettingsDestination) -> Void
    @State private var section = ModelPane.defaults
    @State private var showingConnectionEditor = false
    @State private var modelEditor: ModelEditorSelection?
    @State private var removal: RemovalSelection?
    @State private var search = ""
    @State private var providerSearch = ""
    @State private var connectionSearch = ""
    @State private var useFilter: ModelSelectionUse?

    private enum ModelPane: Hashable { case pool, defaults }
    private struct ModelEditorSelection: Identifiable {
        let id = UUID()
        let connection: ProviderConnection
        let existing: ModelDescriptor?
        let route: ModelRoute?
        let initialModelID: String
    }
    private enum RemovalSelection { case provider(ProviderConnection), model(ModelDescriptor) }

    var body: some View {
        VStack(spacing: 0) {
            MiraSettingsPage {
                switch destination {
                case .category(.models): models
                case .provider(let id):
                    if let connection = model.configuration.connections.first(where: { $0.id == id }) {
                        providerDetail(connection)
                    } else {
                        ContentUnavailableView("Connection unavailable", systemImage: "cloud")
                        Button("Manage Providers") { navigate(.category(.providers)) }
                    }
                case .catalogProvider(let id):
                    if let provider = ProviderModelCatalog.bundled.providers.first(where: { $0.id == id }) {
                        catalogDetail(provider)
                    }
                default: providers
                }
            }
            .id(destination)
            if model.error != nil || model.statusKey != nil {
                MiraSettingsDivider()
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) { status }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MiraTheme.Spacing.xxl)
                    .padding(.vertical, MiraTheme.Spacing.md)
                    .background(MiraTheme.Colors.canvas)
                    .accessibilityIdentifier("settings.providers.status")
            }
        }
        .onChange(of: destination, initial: true) { _, next in
            providerSearch = ""
            if case .provider(let id) = next { model.selectedConnectionID = id }
        }
        .onDisappear { model.stopRequests() }
        .sheet(isPresented: $showingConnectionEditor) {
            ProviderConnectionEditor(existing: nil, container: model.container) { id in
                await model.refresh()
                navigate(.provider(id))
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
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            HStack(alignment: .top) {
                MiraSettingsHeader(title: "Providers", subtitle: "Manage provider connections and models.")
                Button("Add Provider", systemImage: "plus") { showingConnectionEditor = true }
                    .disabled(model.isWorking || model.container.isDemo)
            }
            MiraSettingsSearchField(prompt: "Search providers", text: $connectionSearch)
                .accessibilityIdentifier("settings.providers.search")
            MiraSettingsSection {
                LazyVStack(spacing: 0) {
                    ForEach(visibleConnections) { connection in
                        Button { navigate(.provider(connection.id)) } label: {
                            providerRow(name: connection.name, subtitle: connection.baseURL,
                                        state: connection.isEnabled ? "Active" : "Inactive", active: connection.isEnabled)
                        }
                        .accessibilityIdentifier("settings.provider.\(connection.id)")
                        MiraSettingsDivider()
                    }
                    ForEach(visibleCatalogProviders) { provider in
                        Button { navigate(.catalogProvider(provider.id)) } label: {
                            providerRow(name: provider.name, subtitle: provider.baseURL,
                                        state: "Not configured", active: false)
                        }
                        .accessibilityIdentifier("settings.catalog.\(provider.id)")
                        if provider.id != visibleCatalogProviders.last?.id { MiraSettingsDivider() }
                    }
                }
                .buttonStyle(MiraRowButtonStyle())
                if visibleConnections.isEmpty && visibleCatalogProviders.isEmpty {
                    ContentUnavailableView.search(text: connectionSearch)
                }
            }
        }
    }

    private func providerRow(name: String, subtitle: String, state: LocalizedStringKey, active: Bool) -> some View {
        MiraSidebarRow {
            HStack(spacing: MiraTheme.Spacing.lg) {
                Image(systemName: "cloud").font(.system(size: 24)).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                    Text(verbatim: name).font(MiraTheme.Typography.body.weight(.medium))
                    Text(verbatim: subtitle).font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText).lineLimit(1)
                }
                Spacer(minLength: MiraTheme.Spacing.sm)
                Text(state).font(MiraTheme.Typography.caption)
                    .foregroundStyle(active ? Color.green : MiraTheme.Colors.secondaryText)
                Image(systemName: "chevron.right").font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            .padding(.vertical, MiraTheme.Spacing.md)
        }
    }

    private var visibleConnections: [ProviderConnection] {
        model.configuration.connections.filter { matchesConnectionSearch($0.name, address: $0.baseURL) }
    }

    private var visibleCatalogProviders: [CatalogProvider] {
        let configuredIDs = Set(model.configuration.connections.compactMap { ProviderModelCatalog.bundled.matchingProvider(for: $0)?.id })
        return ProviderModelCatalog.bundled.providers.filter {
            !configuredIDs.contains($0.id) && matchesConnectionSearch($0.name, address: $0.baseURL)
        }
    }

    private func matchesConnectionSearch(_ name: String, address: String) -> Bool {
        let query = connectionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedStandardContains(query) || address.localizedStandardContains(query)
    }

    private func catalogDetail(_ provider: CatalogProvider) -> some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            providerHeading(name: provider.name, address: provider.baseURL)
            ProviderConnectionEditor(existing: nil, container: model.container,
                                     initialTemplateID: provider.id, isEmbedded: true) { id in
                await model.refresh()
                navigate(.provider(id))
            }.id(provider.id)
        }
    }

    private func providerHeading(name: String, address: String) -> some View {
        HStack(spacing: MiraTheme.Spacing.lg) {
            Image(systemName: "cloud").font(.system(size: 32)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                Text(verbatim: name).font(MiraTheme.Typography.title)
                Text(verbatim: address).foregroundStyle(MiraTheme.Colors.secondaryText).textSelection(.enabled)
            }
        }
    }

    private func providerDetail(_ connection: ProviderConnection) -> some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            HStack {
                providerHeading(name: connection.name, address: connection.baseURL)
                Spacer()
                Toggle("Active", isOn: Binding(get: { connection.isEnabled }, set: { enabled in
                    Task { await model.setProviderEnabled(enabled, connection: connection) }
                }))
                .toggleStyle(.switch).fixedSize()
                .disabled(model.isWorking || model.container.isDemo)
                .accessibilityIdentifier("settings.provider.active")
            }
            ProviderConnectionEditor(existing: connection, container: model.container, isEmbedded: true) { _ in
                await model.refresh()
            }.id(connection.id)
            HStack(alignment: .top) {
                Text("Activation allows explicit model requests. It does not verify connectivity or enable any models automatically.")
                    .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                Spacer()
                Button("Remove", role: .destructive) { removal = .provider(connection) }
                    .disabled(model.isWorking || model.container.isDemo)
            }
            HStack {
                Text("Provider Models").font(MiraTheme.Typography.body.weight(.semibold))
                Spacer()
                if model.isDiscovering {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelDiscovery() }
                } else {
                    Button("Fetch Models", systemImage: "arrow.clockwise") { model.discoverModels() }
                        .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                }
                Button("Add Manually", systemImage: "plus") { editModel(nil, connection: connection) }
                    .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
            }
            if !connection.isEnabled {
                Label("Activate this provider to fetch or add models.", systemImage: "pause.circle")
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            MiraSettingsSearchField(prompt: "Search provider models", text: $providerSearch)
            Text("The bundled catalog supplies model information, not account access. Fetch Models checks the provider list; catalog entries may be unavailable for your account.")
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            providerModelList(connection)
        }
    }

    private func providerModelList(_ connection: ProviderConnection) -> some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            if !model.providerModels.isEmpty {
                MiraSettingsSection("Saved Models") {
                    LazyVStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
                        ForEach(model.providerModels.filter { matchesProviderSearch($0.modelID) }) { descriptor in
                            HStack {
                                VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                                    Text(verbatim: descriptor.modelID).font(MiraTheme.Typography.body.weight(.medium))
                                    modelReadiness(descriptor)
                                }
                                Spacer()
                                Button("Configure") { editModel(descriptor, connection: connection) }
                                    .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                                Toggle("In Model Pool", isOn: Binding(get: { descriptor.isEnabled }, set: { enabled in
                                    Task { await model.setModelEnabled(enabled, model: descriptor) }
                                })).labelsHidden().toggleStyle(.switch)
                                    .accessibilityLabel(Text(L10n.format("Include %@ in Model Pool", locale: locale, descriptor.modelID)))
                                    .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                            }
                            .contextMenu {
                                Button("Remove", role: .destructive) { removal = .model(descriptor) }
                                    .disabled(model.isWorking || model.container.isDemo)
                            }
                        }
                    }
                }
            }
            if !model.newDiscoveredModels.isEmpty {
                MiraSettingsSection("Available from Provider") {
                    LazyVStack(spacing: MiraTheme.Spacing.lg) {
                        ForEach(model.newDiscoveredModels.filter { matchesProviderSearch($0.id, name: $0.displayName) }) { discovered in
                            availableModelRow(id: discovered.id, name: discovered.displayName, connection: connection)
                        }
                    }
                }
            }
            if !model.newCatalogModels.isEmpty {
                MiraSettingsSection("Bundled Catalog · models.dev") {
                    LazyVStack(spacing: MiraTheme.Spacing.lg) {
                        ForEach(model.newCatalogModels.filter { matchesProviderSearch($0.id, name: $0.metadata.displayName) }) { item in
                            availableModelRow(id: item.id, name: item.metadata.displayName, connection: connection,
                                              reasoning: item.metadata.reasoning == true)
                        }
                    }
                }
            }
            if model.providerModels.isEmpty && model.newDiscoveredModels.isEmpty && model.newCatalogModels.isEmpty {
                ContentUnavailableView("No Models Selected", systemImage: "cube.transparent",
                                       description: Text("Fetch the model list or add a Model ID manually, then configure the models you want to use."))
            }
        }
    }

    private func availableModelRow(id: String, name: String?, connection: ProviderConnection, reasoning: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                Text(verbatim: name ?? id).font(MiraTheme.Typography.body.weight(.medium))
                if let name, name != id {
                    Text(verbatim: id).font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                }
                if reasoning {
                    Label("Thinking", systemImage: "brain")
                        .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                }
            }
            Spacer()
            Button("Add to Pool") { editModel(nil, connection: connection, modelID: id) }
                .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            MiraSettingsHeader(title: "Models", subtitle: "Choose default models and manage your model pool.")
            Picker("Configuration section", selection: $section) {
                Text("Purpose Defaults").tag(ModelPane.defaults)
                Text("Model Pool").tag(ModelPane.pool)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                .accessibilityIdentifier("settings.models.section")
            switch section {
            case .pool: pool
            case .defaults:
                PurposeRoutingView(configuration: model.configuration, workspaces: model.workspaces,
                                   conversations: model.conversations, container: model.container, onChange: { await model.refresh() })
            }
        }
    }

    private var pool: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
            MiraSettingsSearchField(prompt: "Search models or providers", text: $search)
            Picker("Filter by use", selection: $useFilter) {
                Text("All Models").tag(nil as ModelSelectionUse?)
                Text("Conversation").tag(Optional(ModelSelectionUse.conversation))
                Text("Agent Tools").tag(Optional(ModelSelectionUse.agentTools))
                Text("Memory Extraction").tag(Optional(ModelSelectionUse.memoryExtraction))
            }.pickerStyle(.segmented).labelsHidden()
            ForEach(filteredPool) { entry in
                MiraSettingsSection {
                    HStack {
                        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                            Text(verbatim: entry.model.modelID).font(MiraTheme.Typography.body.weight(.semibold))
                            Text(verbatim: entry.connection.name).font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                        }
                        Spacer()
                        Button("Configure") { editModel(entry.model, connection: entry.connection) }
                        Menu("More") {
                            Button("Disable") { Task { await model.setModelEnabled(false, model: entry.model) } }
                            Button("Remove", role: .destructive) { removal = .model(entry.model) }
                        }.fixedSize()
                    }
                    modelReadiness(entry.model)
                    MiraSettingsDivider()
                    HStack {
                        Button("Test Text") { model.probe(entry.model, kind: .text) }
                        Button("Test Tools") { model.probe(entry.model, kind: .tools) }
                        Button("Test JSON Extraction") { model.probe(entry.model, kind: .jsonExtraction) }
                    }.disabled(model.isProbing)
                }.disabled(model.isWorking || model.container.isDemo)
            }
            if filteredPool.isEmpty {
                ContentUnavailableView("No Matching Models", systemImage: "square.stack.3d.up",
                                       description: Text("Clear the search or filter, or configure model capabilities under All Models. Only active providers contribute to the pool."))
            }
            HStack {
                Button("Manage Providers") { navigate(.category(.providers)) }
                if model.isProbing { ProgressView().controlSize(.small); Button("Cancel Test") { model.cancelProbe() } }
            }
            Text("Capability tests send a fixed synthetic prompt without conversation history. Your provider may charge for the request.")
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
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
    }
}
