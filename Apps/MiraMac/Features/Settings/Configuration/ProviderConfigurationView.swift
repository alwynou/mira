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
    @State private var connectionEditor: ProviderConnectionSettingsModel?
    @State private var editorDestination: SettingsDestination?
    @State private var connectionEditors: [SettingsDestination: ProviderConnectionSettingsModel] = [:]
    private struct ModelEditorSelection: Identifiable {
        let id = UUID()
        let connection: ProviderConnection
        let existing: ModelDescriptor?
        let route: ModelRoute?
        let initialModelID: String
    }

    var body: some View {
        Group {
            if destination.category == .models {
                MiraSettingsPage {
                    models
                    if hasModelFeedback { MiraSettingsSection { modelFeedback } }
                }
            } else {
                providers
            }
        }
        .onChange(of: selectedProviderDestination, initial: true) { _, next in
            if case .provider(let id) = next {
                model.selectedConnectionID = id
            } else {
                model.selectedConnectionID = nil
            }
            updateConnectionEditor()
        }
        .onChange(of: model.configuration) { updateConnectionEditor() }
        .onDisappear {
            for editor in connectionEditors.values { editor.disappear() }
            model.stopRequests()
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
                if let target { Task { await model.removeModel(target) } }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Removal also deletes the related model presets and default selections. Disable the item to keep its configuration.")
        }
    }

    private var providers: some View {
        MiraSettingsLazyPage(header: {
            MiraSettingsSection("Provider") {
                providerCards
            }
            connectionFields
        }) {
            selectedProviderContent
        }
        .accessibilityIdentifier("settings.providers.page")
    }

    private struct ProviderChoice: Identifiable {
        let id: SettingsDestination
        let name: String
        let providerID: String
        let accessibilityIdentifier: String
    }

    private var providerChoices: [ProviderChoice] {
        ProviderModelCatalog.bundled.directoryProviders.flatMap { provider in
            let connections = listedConnections.filter { directoryProvider(for: $0)?.directoryID == provider.directoryID }
            if connections.isEmpty {
                return [ProviderChoice(id: .catalogProvider(provider.id), name: provider.name, providerID: provider.id,
                                       accessibilityIdentifier: "settings.catalog.\(provider.id)")]
            }
            return connections.map { connection in
                ProviderChoice(id: .provider(connection.id), name: ProviderModelCatalog.bundled.displayName(for: connection),
                               providerID: provider.id, accessibilityIdentifier: "settings.provider.\(connection.id)")
            }
        }
    }

    private var providerCards: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(providerChoices) { choice in
                        MiraProviderSelectionCard(name: choice.name, providerID: choice.providerID,
                                                  isSelected: selectedProviderDestination == choice.id) {
                            navigate(choice.id)
                        }
                        .id(choice.id)
                        .accessibilityIdentifier(choice.accessibilityIdentifier)
                    }
                }
                .padding(MiraTheme.Spacing.xs)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: selectedProviderDestination, initial: true) { _, selected in
                if let selected { reader.scrollTo(selected, anchor: .center) }
            }
        }
        .accessibilityIdentifier("settings.providers.cards")
    }

    @ViewBuilder private var selectedProviderContent: some View {
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
            MiraSettingsSection {
                ContentUnavailableView("Connection unavailable", systemImage: "cloud")
                if hasModelFeedback { modelFeedback }
            }
        }
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
        Group {
            MiraSettingsSection("Provider Models", isCollection: true) {
                modelListIntroduction(isEmpty: provider.models.isEmpty)
                ForEach(provider.models) { item in
                    MiraSettingsLazyRow(isFirst: false, isLast: item.id == provider.models.last?.id) {
                        modelRow(id: item.id, name: item.metadata.displayName, metadata: item.metadata,
                                 providerID: provider.id, isEnabled: .constant(false))
                            .disabled(true)
                    }
                }
            }
        }
    }

    private func providerDetail(_ connection: ProviderConnection) -> some View {
        Group {
            MiraSettingsSection("Provider Models", isCollection: true, actions: {
                providerModelActions(connection)
            }) {
                modelListIntroduction(isEmpty: false)
                providerModelRows(connection)
            }
        }
    }

    @ViewBuilder private var connectionFields: some View {
        if let connectionEditor, editorDestination == selectedProviderDestination {
            let editingDestination = editorDestination
            ProviderConnectionEditor(settings: connectionEditor,
                                     isUnavailable: model.isWorking || model.container.isDemo,
                                     onMutation: { model.stopRequests() }) { updated in
                await model.refresh(ifMissing: updated)
                if editorDestination == editingDestination { navigate(.provider(updated.id)) }
            }
            .id(editorDestination)
            #if DEBUG
            .onAppear { ProviderSettingsTiming.didLayout(editorDestination) }
            #endif
        }
    }

    /// Ownership stays above the lazy rows so scrolling cannot discard a key draft or cancel a test.
    private func updateConnectionEditor() {
        let destination = selectedProviderDestination
        let connection: ProviderConnection?
        let template: CatalogProvider?
        switch destination {
        case .provider(let id):
            connection = model.configuration.connections.first { $0.id == id }
            template = connection.flatMap { ProviderModelCatalog.bundled.matchingProvider(for: $0) }
        case .catalogProvider(let id):
            connection = nil
            template = ProviderModelCatalog.bundled.directoryProviders.first { $0.id == id }
        default:
            connectionEditor = nil; editorDestination = nil
            return
        }
        if let destination, editorDestination != destination {
            let editor = connectionEditors[destination] ?? ProviderConnectionSettingsModel(existing: connection, template: template, container: model.container)
            connectionEditors[destination] = editor
            connectionEditor = editor
            editorDestination = destination
        }
        connectionEditor?.update(existing: connection, configuration: model.configuration)
    }

    private func providerModelActions(_ connection: ProviderConnection) -> some View {
        HStack(spacing: MiraTheme.Spacing.sm) {
            if model.isDiscovering {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelDiscovery() }
            } else {
                Button { model.discoverModels() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Fetch Models").accessibilityLabel("Fetch Models")
                    .accessibilityIdentifier("settings.provider.models.refresh")
                    .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
            }
            Button { editModel(nil, connection: connection) } label: { Image(systemName: "plus") }
                .help("Add Manually").accessibilityLabel("Add Manually")
                .accessibilityIdentifier("settings.provider.models.add")
                .disabled(model.isWorking || model.container.isDemo)
        }
        .buttonStyle(MiraSettingsButtonStyle())
        .controlSize(.small)
    }

    private var providerModelsDescription: some View {
        Text("The bundled catalog supplies model information, not account access. Fetch Models checks the provider list; catalog entries may be unavailable for your account.")
            .font(MiraTheme.Settings.caption)
            .foregroundStyle(MiraTheme.Settings.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func modelListIntroduction(isEmpty: Bool) -> some View {
        MiraSettingsLazyRow(isFirst: true, isLast: isEmpty) {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                providerModelsDescription
                if hasModelFeedback { modelFeedback }
            }
        }
    }

    @ViewBuilder private func providerModelRows(_ connection: ProviderConnection) -> some View {
        let providerID = ProviderModelCatalog.bundled.matchingProvider(for: connection)?.id
        let saved = model.providerModels
        let discovered = model.newDiscoveredModels
        let catalog = model.newCatalogModels
        ForEach(saved) { descriptor in
            MiraSettingsLazyRow(isFirst: false, isLast: discovered.isEmpty && catalog.isEmpty && descriptor.id == saved.last?.id) {
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
        }
        ForEach(discovered) { item in
            MiraSettingsLazyRow(isFirst: false, isLast: catalog.isEmpty && item.id == discovered.last?.id) {
                availableModelRow(id: item.id, name: item.displayName, connection: connection)
            }
        }
        ForEach(catalog) { item in
            MiraSettingsLazyRow(isFirst: false, isLast: item.id == catalog.last?.id) {
                availableModelRow(id: item.id, name: item.metadata.displayName, connection: connection)
            }
        }
        if saved.isEmpty && discovered.isEmpty && catalog.isEmpty {
            MiraSettingsLazyRow(isFirst: false, isLast: true) {
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
        Group {
            PurposeRoutingView(configuration: model.configuration, workspaces: model.workspaces,
                               conversations: model.conversations, container: model.container,
                               onChange: { await model.refresh() })
            MiraSettingsSection {
                HStack {
                    Spacer()
                    Button("Manage Providers") { navigate(.category(.providers)) }
                        .buttonStyle(MiraSettingsButtonStyle())
                }
            }
        }
    }

    private func editModel(_ descriptor: ModelDescriptor?, connection: ProviderConnection, modelID: String = "") {
        model.cancelProbe()
        let route = descriptor.flatMap { item in model.configuration.routes.first { $0.id == item.poolRouteID } }
        modelEditor = ModelEditorSelection(connection: connection, existing: descriptor, route: route, initialModelID: modelID)
    }

    private var hasModelFeedback: Bool { model.error != nil || model.statusKey != nil }

    private var modelFeedback: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
            if let error = model.error {
                Text(L10n.error(error, locale: locale)).foregroundStyle(.red).textSelection(.enabled)
            } else if let key = model.statusKey {
                Text(L10n.string(key, locale: locale)).foregroundStyle(MiraTheme.Settings.secondaryText)
            }
            if model.isProbing {
                Button("Cancel Test") { model.cancelProbe() }.buttonStyle(MiraSettingsButtonStyle())
            }
        }
        .font(MiraTheme.Settings.caption)
        .accessibilityIdentifier("settings.provider.models.status")
    }
}
