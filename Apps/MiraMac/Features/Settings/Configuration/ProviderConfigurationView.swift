import SwiftUI
import MiraCore
import MiraProviders

struct ProviderConfigurationView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: ProviderLibraryModel
    let destination: SettingsDestination
    let navigate: (SettingsDestination) -> Void
    @State private var modelEditor: ModelEditorSelection?
    @State private var removal: ModelDescriptor?
    private struct ModelEditorSelection: Identifiable {
        let id = UUID()
        let connection: ProviderConnection
        let existing: ModelDescriptor?
        let route: ModelRoute?
        let initialModelID: String
    }

    var body: some View {
        VStack(spacing: 0) {
            if destination.category == .models {
                MiraSettingsPage { models }
            } else {
                providers
            }
            if model.error != nil || model.statusKey != nil {
                MiraSettingsDivider()
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                    status
                    if model.isProbing {
                        Button("Cancel Test") { model.cancelProbe() }.buttonStyle(MiraSettingsButtonStyle())
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MiraTheme.Spacing.xxl)
                    .padding(.vertical, MiraTheme.Spacing.md)
                    .background(MiraTheme.Colors.canvas)
                    .accessibilityIdentifier("settings.providers.status")
            }
        }
        .onChange(of: selectedProviderDestination, initial: true) { _, next in
            if case .provider(let id) = next {
                model.selectedConnectionID = id
            } else {
                model.selectedConnectionID = nil
            }
        }
        .onDisappear { model.stopRequests() }
        .sheet(item: $modelEditor) { selection in
            PoolModelEditor(existing: selection.existing, connection: selection.connection, route: selection.route,
                            initialModelID: selection.initialModelID, container: model.container,
                            onSaved: { await model.refresh() })
                .environment(\.locale, locale)
        }
        .confirmationDialog("Remove configuration?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                let target = removal; removal = nil
                if let target { Task { await model.removeModel(target) } }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Removal also deletes the related model presets and default selections. Disable the item to keep its configuration.")
        }
    }

    private var providers: some View {
        MiraSettingsSplitPage(title: "Providers", subtitle: "Manage provider connections and models.") {
            LazyVStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
                if !activeConnections.isEmpty {
                    MiraProviderGroup("Active Providers") {
                        ForEach(activeConnections) { connection in
                            connectionRow(connection)
                        }
                    }
                }
                if !inactiveConnections.isEmpty || !unconfiguredProviders.isEmpty {
                    MiraProviderGroup("Inactive Providers") {
                        ForEach(inactiveConnections) { connection in
                            connectionRow(connection)
                        }
                        ForEach(unconfiguredProviders) { provider in
                            Button { navigate(.catalogProvider(provider.id)) } label: {
                                MiraProviderRow(name: provider.name, providerID: provider.id, state: "Not configured",
                                                isSelected: selectedProviderDestination == .catalogProvider(provider.id))
                            }
                            .accessibilityIdentifier("settings.catalog.\(provider.id)")
                        }
                    }
                }
            }
            .buttonStyle(MiraRowButtonStyle())
            .accessibilityIdentifier("settings.providers.list")
        } detail: {
            Group {
                switch selectedProviderDestination {
                case .provider(let id):
                    if let connection = model.configuration.connections.first(where: { $0.id == id }) {
                        providerDetail(connection)
                    }
                case .catalogProvider(let id):
                    if let provider = unconfiguredProviders.first(where: { $0.id == id }) {
                        catalogDetail(provider)
                    }
                default:
                    ContentUnavailableView("Connection unavailable", systemImage: "cloud")
                }
            }
            .id(selectedProviderDestination)
        }
    }

    private func connectionRow(_ connection: ProviderConnection) -> some View {
        Button { navigate(.provider(connection.id)) } label: {
            MiraProviderRow(
                name: ProviderModelCatalog.bundled.displayName(for: connection),
                providerID: directoryProvider(for: connection)?.id,
                state: connection.isEnabled ? "Active" : "Inactive",
                isSelected: selectedProviderDestination == .provider(connection.id),
                isActive: connection.isEnabled
            )
        }
        .accessibilityIdentifier("settings.provider.\(connection.id)")
    }

    private func directoryProvider(for connection: ProviderConnection) -> CatalogProvider? {
        if let provider = ProviderModelCatalog.bundled.matchingProvider(for: connection) { return provider }
        // A proxy keeps the template's service name. This lookup is only for directory visibility;
        // model metadata and request capabilities still require exact endpoint matching.
        return ProviderModelCatalog.bundled.directoryProviders.first {
            $0.name == connection.name && $0.providerKind == connection.providerKind
        }
    }

    private var listedConnections: [ProviderConnection] {
        model.configuration.connections.filter { directoryProvider(for: $0) != nil }
    }

    private var activeConnections: [ProviderConnection] { listedConnections.filter(\.isEnabled) }

    private var inactiveConnections: [ProviderConnection] { listedConnections.filter { !$0.isEnabled } }

    private var unconfiguredProviders: [CatalogProvider] {
        let configuredIDs = Set(listedConnections.compactMap { directoryProvider(for: $0)?.directoryID })
        return ProviderModelCatalog.bundled.directoryProviders.filter { !configuredIDs.contains($0.directoryID) }
    }

    private var selectedProviderDestination: SettingsDestination? {
        guard destination.category == .providers else { return nil }
        switch destination {
        case .provider(let id) where listedConnections.contains(where: { $0.id == id }):
            return destination
        case .catalogProvider(let id) where unconfiguredProviders.contains(where: { $0.id == id }):
            return destination
        default:
            if let first = activeConnections.first ?? inactiveConnections.first { return .provider(first.id) }
            return unconfiguredProviders.first.map { .catalogProvider($0.id) }
        }
    }

    private func catalogDetail(_ provider: CatalogProvider) -> some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            ProviderConnectionEditor(existing: nil, template: provider, library: model,
                                     onMutation: { model.stopRequests() }) { id in
                await model.refresh()
                navigate(.provider(id))
            }
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                Text("Provider Models").font(MiraTheme.Typography.body.weight(.semibold))
                providerModelsDescription
                MiraProviderModelList(rowCount: provider.models.count) {
                    ForEach(provider.models) { item in
                        if item.id != provider.models.first?.id { MiraSettingsDivider() }
                        modelRow(id: item.id, name: item.metadata.displayName, metadata: item.metadata,
                                 providerID: provider.id, isEnabled: .constant(false))
                            .disabled(true)
                    }
                }
            }
        }
    }

    private func providerDetail(_ connection: ProviderConnection) -> some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            ProviderConnectionEditor(existing: connection,
                                     template: ProviderModelCatalog.bundled.matchingProvider(for: connection), library: model,
                                     onMutation: { navigate(.provider(connection.id)); model.stopRequests() }) { id in
                await model.refresh()
                navigate(.provider(id))
            }
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                HStack {
                    Text("Provider Models").font(MiraTheme.Typography.body.weight(.semibold))
                    Spacer(minLength: 0)
                    if model.isDiscovering {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelDiscovery() }
                    } else {
                        Button { model.discoverModels() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Fetch Models").accessibilityLabel("Fetch Models")
                            .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                    }
                    Button { editModel(nil, connection: connection) } label: { Image(systemName: "plus") }
                        .help("Add Manually").accessibilityLabel("Add Manually")
                        .disabled(model.isWorking || model.container.isDemo)
                }
                .controlSize(.small)
                providerModelsDescription
            }
            providerModelList(connection)
        }
    }

    private var providerModelsDescription: some View {
        Text("The bundled catalog supplies model information, not account access. Fetch Models checks the provider list; catalog entries may be unavailable for your account.")
            .font(MiraTheme.Typography.caption)
            .foregroundStyle(MiraTheme.Colors.settingsDescription)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func providerModelList(_ connection: ProviderConnection) -> some View {
        let providerID = ProviderModelCatalog.bundled.matchingProvider(for: connection)?.id
        let rowCount = model.providerModels.count + model.newDiscoveredModels.count + model.newCatalogModels.count
        return MiraProviderModelList(rowCount: rowCount) {
            ForEach(model.providerModels) { descriptor in
                if descriptor.id != model.providerModels.first?.id { MiraSettingsDivider() }
                modelRow(id: descriptor.modelID, name: descriptor.catalogMetadata?.displayName,
                         metadata: descriptor.catalogMetadata, providerID: providerID,
                         contextWindow: descriptor.contextWindow,
                         supportsTools: descriptor.toolCapability == .declared || descriptor.toolCapability == .verified,
                         isEnabled: Binding(get: { descriptor.isEnabled }, set: { enabled in
                             Task { await model.setModelEnabled(enabled, model: descriptor) }
                         }))
                    .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                    .contextMenu {
                        Button("Configure") { editModel(descriptor, connection: connection) }
                            .disabled(model.isWorking || model.container.isDemo)
                        Menu("Test Capabilities") {
                            Button("Test Text") { model.probe(descriptor, kind: .text) }
                            Button("Test Tools") { model.probe(descriptor, kind: .tools) }
                            Button("Test JSON Extraction") { model.probe(descriptor, kind: .jsonExtraction) }
                        }
                        .disabled(!connection.isEnabled || model.isWorking || model.isProbing || model.container.isDemo)
                        Button("Remove", role: .destructive) { removal = descriptor }
                            .disabled(model.isWorking || model.container.isDemo)
                    }
            }
            ForEach(model.newDiscoveredModels) { discovered in
                if !model.providerModels.isEmpty || discovered.id != model.newDiscoveredModels.first?.id { MiraSettingsDivider() }
                availableModelRow(id: discovered.id, name: discovered.displayName, connection: connection)
            }
            ForEach(model.newCatalogModels) { item in
                if !model.providerModels.isEmpty || !model.newDiscoveredModels.isEmpty || item.id != model.newCatalogModels.first?.id { MiraSettingsDivider() }
                availableModelRow(id: item.id, name: item.metadata.displayName, connection: connection)
            }
            if model.providerModels.isEmpty && model.newDiscoveredModels.isEmpty && model.newCatalogModels.isEmpty {
                ContentUnavailableView("No Models Selected", systemImage: "cube.transparent",
                                       description: Text("Fetch the model list or add a Model ID manually, then configure the models you want to use."))
            }
        }
    }

    private func availableModelRow(id: String, name: String?, connection: ProviderConnection) -> some View {
        let catalog = ProviderModelCatalog.bundled.model(for: connection, modelID: id)
        return modelRow(id: id, name: name ?? catalog?.metadata.displayName, metadata: catalog?.metadata,
                        providerID: ProviderModelCatalog.bundled.matchingProvider(for: connection)?.id,
                        isEnabled: Binding(get: { false }, set: { enabled in
                            guard enabled else { return }
                            if let catalog, ProviderConnectionTestModel(catalog: catalog, connection: connection).canTest(with: connection) {
                                Task { await model.addCatalogModel(catalog, connection: connection) }
                            } else {
                                editModel(nil, connection: connection, modelID: id)
                            }
                        }))
            .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
            .contextMenu {
                Button("Configure") { editModel(nil, connection: connection, modelID: id) }
                    .disabled(model.isWorking || model.container.isDemo)
            }
    }

    private func modelRow(id: String, name: String?, metadata: ModelCatalogMetadata?, providerID: String?,
                          contextWindow: Int? = nil,
                          supportsTools: Bool = false, isEnabled: Binding<Bool>) -> some View {
        let pricing = metadata?.pricing.map {
            MiraProviderModelRow.Pricing(input: CostPresentation.amount($0.input, locale: locale),
                                         output: CostPresentation.amount($0.output, locale: locale))
        }
        return MiraProviderModelRow(name: name ?? id, modelID: id, pricing: pricing, providerID: providerID,
                             supportsVision: metadata?.inputModalities.contains("image") == true,
                             supportsTools: supportsTools || metadata?.toolCall == true,
                             supportsThinking: metadata?.reasoning == true,
                             contextWindow: contextWindow ?? metadata?.contextWindow, isEnabled: isEnabled)
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            MiraSettingsHeader(title: "Models", subtitle: "Choose models for conversations and memory.")
            PurposeRoutingView(configuration: model.configuration, workspaces: model.workspaces,
                               conversations: model.conversations, container: model.container,
                               onChange: { await model.refresh() })
            HStack {
                Spacer()
                Button("Manage Providers") { navigate(.category(.providers)) }
                    .buttonStyle(MiraSettingsButtonStyle())
            }
        }
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
