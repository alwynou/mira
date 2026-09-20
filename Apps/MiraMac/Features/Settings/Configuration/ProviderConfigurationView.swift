import MiraCore
import MiraProviders
import SwiftUI

struct ProviderConfigurationView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: ProviderLibraryModel
    let destination: SettingsDestination
    let navigate: (SettingsDestination) -> Void
    @State private var modelEditor: ModelEditorSelection?
    @State private var removal: AgentConfiguredModel?
    @State private var connectionEditor: ProviderConnectionSettingsModel?
    @State private var editorDestination: SettingsDestination?
    @State private var connectionEditors: [SettingsDestination: ProviderConnectionSettingsModel] = [:]
    private struct ModelEditorSelection: Identifiable {
        let id = UUID()
        let connection: AgentConfiguredConnection
        let existing: AgentConfiguredModel?
        let preset: AgentRoutePreset?
        let library: MacLibrary
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
        .onChange(of: model.revision) { updateConnectionEditor() }
        .onDisappear {
            for editor in connectionEditors.values { editor.disappear() }
            model.cancelDiscovery()
            model.cancelProbe()
        }
        .sheet(item: $modelEditor) { selection in
            PoolModelEditor(
                existing: selection.existing, connection: selection.connection, preset: selection.preset,
                initialModelID: selection.initialModelID, library: selection.library, isDemo: model.container.isDemo,
                onSaved: { await model.refresh() }
            )
            .environment(\.locale, locale)
        }
        .confirmationDialog(
            "Remove configuration?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                let target = removal
                removal = nil
                if let target { Task { await model.removeModel(target) } }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text(
                "Removing this model deletes its model configuration. Saved default references remain and will be shown as unavailable until you choose another model."
            )
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
        // Catalog and saved-provider rows can share model IDs, but their
        // bindings and disabled state differ. Recreate the owner when the
        // persisted connection replaces the catalog placeholder so realized
        // native controls do not retain the catalog binding.
        .id(selectedProviderDestination)
        .accessibilityIdentifier("settings.providers.page")
    }

    private struct ProviderChoice: Identifiable {
        let id: SettingsDestination
        let name: String
        let providerID: String?
        let accessibilityIdentifier: String
    }

    private var providerChoices: [ProviderChoice] {
        let known = model.catalog.directoryProviders.flatMap { provider in
            let connections = listedConnections.filter {
                directoryProvider(for: $0)?.directoryID == provider.directoryID
            }
            if connections.isEmpty {
                return [
                    ProviderChoice(
                        id: .catalogProvider(provider.id), name: L10n.string(provider.name, locale: locale), providerID: provider.id,
                        accessibilityIdentifier: "settings.catalog.\(provider.id)")
                ]
            }
            return connections.map { connection in
                ProviderChoice(
                    id: .provider(connection.id), name: localizedDisplayName(for: connection),
                    providerID: provider.id, accessibilityIdentifier: "settings.provider.\(connection.id.rawValue.uuidString)")
            }
        }
        return known
            + listedConnections.filter { directoryProvider(for: $0) == nil }.map {
                ProviderChoice(
                    id: .provider($0.id), name: localizedDisplayName(for: $0), providerID: nil,
                    accessibilityIdentifier: "settings.provider.\($0.id.rawValue.uuidString)")
            }
            + [ProviderChoice(
                id: .catalogProvider("custom"), name: L10n.string("Custom provider", locale: locale), providerID: nil,
                accessibilityIdentifier: "settings.catalog.custom")]
    }

    private var providerCards: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(providerChoices) { choice in
                        MiraProviderSelectionCard(
                            name: choice.name, providerID: choice.providerID,
                            isSelected: selectedProviderDestination == choice.id
                        ) {
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
            if let connection = model.connections.first(where: { $0.id == id }) {
                providerDetail(connection)
            }
        case .catalogProvider(let id):
            if id == "custom" {
                customDetail
            } else if let provider = unconfiguredProviders.first(where: { $0.id == id }) {
                catalogDetail(provider)
            }
        default:
            MiraSettingsSection {
                ContentUnavailableView("Connection unavailable", systemImage: "cloud")
                if hasModelFeedback { modelFeedback }
            }
        }
    }

    private func directoryProvider(for connection: AgentConfiguredConnection) -> CatalogProvider? {
        if let provider = model.catalog.matchingProvider(for: connection) { return provider }
        // A proxy keeps the template's service name. This lookup is only for directory visibility;
        // model metadata and request capabilities still require exact endpoint matching.
        return model.catalog.directoryProviders.first {
            $0.name == connection.name
        }
    }

    private func localizedDisplayName(for connection: AgentConfiguredConnection) -> String {
        let value = model.catalog.displayName(for: connection)
        if let provider = directoryProvider(for: connection),
            connection.definitionID == provider.id, value == provider.name {
            return L10n.string(provider.name, locale: locale)
        }
        if connection.definitionID == nil, value == "Custom provider" {
            return L10n.string("Custom provider", locale: locale)
        }
        return value
    }

    private var listedConnections: [AgentConfiguredConnection] {
        model.connections
    }

    private var activeConnections: [AgentConfiguredConnection] { listedConnections.filter(\.isEnabled) }

    private var inactiveConnections: [AgentConfiguredConnection] { listedConnections.filter { !$0.isEnabled } }

    private var unconfiguredProviders: [CatalogProvider] {
        let configuredIDs = Set(listedConnections.compactMap { directoryProvider(for: $0)?.directoryID })
        return model.catalog.directoryProviders.filter { !configuredIDs.contains($0.directoryID) }
    }

    private var selectedProviderDestination: SettingsDestination? {
        guard destination.category == .providers else { return nil }
        switch destination {
        case .provider(let id) where listedConnections.contains(where: { $0.id == id }):
            return destination
        case .catalogProvider(let id):
            if id == "custom" { return destination }
            // A catalog destination may survive one render after its
            // connection is persisted. Resolve it before falling back to a
            // different active provider; this selection belongs to the
            // connection created from the catalog entry.
            if let connection = model.configuredConnection(forCatalogProviderID: id) {
                return .provider(connection.id)
            }
            if unconfiguredProviders.contains(where: { $0.id == id }) { return destination }
            if let first = activeConnections.first ?? inactiveConnections.first { return .provider(first.id) }
            return unconfiguredProviders.first.map { .catalogProvider($0.id) }
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
                        modelRow(
                            id: item.id, name: item.metadata.displayName, metadata: item.metadata,
                            providerID: provider.id, isEnabled: .constant(false)
                        )
                        .disabled(true)
                    }
                }
            }
        }
    }

    private var customDetail: some View {
        MiraSettingsSection("Custom Provider") {
            Text("Use a compatible HTTP endpoint and choose its protocol once. Model IDs can be added after saving.")
                .font(MiraTheme.Settings.caption).foregroundStyle(MiraTheme.Settings.secondaryText)
        }
    }

    private func providerDetail(_ connection: AgentConfiguredConnection) -> some View {
        Group {
            MiraSettingsSection(
                "Provider Models", isCollection: true,
                actions: {
                    providerModelActions(connection)
                }
            ) {
                modelListIntroduction(isEmpty: false)
                providerModelRows(connection)
            }
        }
    }

    @ViewBuilder private var connectionFields: some View {
        if let connectionEditor, editorDestination == selectedProviderDestination {
            let editingDestination = editorDestination
            ProviderConnectionEditor(
                settings: connectionEditor,
                isUnavailable: model.isWorking || model.container.isDemo,
                onMutation: {
                    model.cancelDiscovery()
                    model.cancelProbe()
                }
            ) { updated in
                await model.refresh(ifMissing: updated)
                if editorDestination == editingDestination || editorDestination == .provider(updated.id) {
                    navigate(.provider(updated.id))
                }
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
        let connection: AgentConfiguredConnection?
        let template: CatalogProvider?
        switch destination {
        case .provider(let id):
            connection = model.connections.first { $0.id == id }
            template = connection.flatMap { model.catalog.matchingProvider(for: $0) }
        case .catalogProvider(let id):
            connection = nil
            template = model.catalog.directoryProviders.first { $0.id == id }
        default:
            connectionEditor = nil
            editorDestination = nil
            return
        }
        if let destination, editorDestination != destination {
            guard let library = model.container.library else { return }
            let editor =
                connectionEditors[destination]
                ?? ProviderConnectionSettingsModel(
                    existing: connection, template: template, library: library, isDemo: model.container.isDemo)
            connectionEditors[destination] = editor
            connectionEditor = editor
            editorDestination = destination
        }
        connectionEditor?.update(existing: connection, models: model.models, presets: model.presets)
    }

    private func providerModelActions(_ connection: AgentConfiguredConnection) -> some View {
        HStack(spacing: MiraTheme.Spacing.sm) {
            if model.isRefreshingMetadata {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.refreshModelInformation() }
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("Update model information").accessibilityLabel("Update model information")
                .accessibilityIdentifier("settings.provider.models.update-information")
                .disabled(model.isWorking || model.container.isDemo)
            }
            if model.isDiscovering {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelDiscovery() }
            } else {
                Button {
                    model.discoverModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Fetch Models").accessibilityLabel("Fetch Models")
                .accessibilityIdentifier("settings.provider.models.refresh")
                .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
            }
            Button {
                editModel(nil, connection: connection)
            } label: {
                Image(systemName: "plus")
            }
            .help("Add Manually").accessibilityLabel("Add Manually")
            .accessibilityIdentifier("settings.provider.models.add")
            .disabled(model.isWorking || model.container.isDemo)
        }
        .buttonStyle(MiraSettingsButtonStyle())
        .controlSize(.small)
    }

    private var providerModelsDescription: some View {
        Text(
            "The bundled catalog supplies model information, not account access. Fetch Models checks the provider list; catalog entries may be unavailable for your account."
        )
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

    @ViewBuilder private func providerModelRows(_ connection: AgentConfiguredConnection) -> some View {
        let providerID = model.catalog.matchingProvider(for: connection)?.id
        let saved = model.providerModels
        let discovered = model.newDiscoveredModels
        let catalog = model.newCatalogModels
        ForEach(saved) { descriptor in
            let effectiveInvocation = resolvedInvocation(for: descriptor)
            let metadata = model.catalog.model(for: connection, modelID: descriptor.modelID,
                endpointID: effectiveInvocation?.endpointID)?.metadata
            let capabilities = effectiveInvocation.flatMap {
                try? ModelCapabilitySummary(model: descriptor, invocationID: $0.id, catalog: metadata)
            }
            MiraSettingsLazyRow(
                isFirst: false, isLast: discovered.isEmpty && catalog.isEmpty && descriptor.id == saved.last?.id
            ) {
                modelRow(
                    id: descriptor.modelID,
                    name: descriptor.displayName ?? metadata?.displayName,
                    metadata: metadata, providerID: providerID,
                    publishedPricing: model.catalog.publishedPricing(for: connection, modelID: descriptor.modelID,
                        endpointID: effectiveInvocation?.endpointID),
                    contextWindow: effectiveInvocation?.contextWindow,
                    supportsVision: capabilities?.vision ?? false,
                    supportsTools: capabilities?.tools ?? false,
                    supportsThinking: capabilities?.thinking ?? false,
                    isEnabled: Binding(
                        get: { descriptor.isEnabled },
                        set: { enabled in
                            Task { await model.setModelEnabled(enabled, model: descriptor) }
                        })
                )
                .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
                .contextMenu {
                    Button("Configure") { editModel(descriptor, connection: connection) }
                        .disabled(model.isWorking || model.container.isDemo)
                    Menu("Test Capabilities") {
                        ForEach(model.probeDescriptors, id: \.id) { probe in
                            Button(LocalizedStringKey(probe.title)) { model.probe(descriptor, probeID: probe.id) }
                        }
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
                ContentUnavailableView(
                    "No Models Selected", systemImage: "cube.transparent",
                    description: Text(
                        "Fetch the model list or add a Model ID manually, then configure the models you want to use."))
            }
        }
    }

    private func resolvedInvocation(for model: AgentConfiguredModel) -> AgentModelInvocationSpec? {
        let invocationID = self.model.presets.first(where: { $0.modelDescriptorID == model.id })?.invocationID
        let invocation = invocationID.flatMap { id in model.invocations.first(where: { $0.id == id }) }
            ?? model.invocations.first
        guard let invocation else { return nil }
        return try? AgentModelMetadataResolver.resolve(invocation, facts: model.facts)
    }

    private func availableModelRow(id: String, name: String?, connection: AgentConfiguredConnection) -> some View {
        let catalog = model.catalog.model(for: connection, modelID: id)
        return modelRow(
            id: id, name: name ?? catalog?.metadata.displayName, metadata: catalog?.metadata,
            providerID: model.catalog.matchingProvider(for: connection)?.id,
            publishedPricing: model.catalog.publishedPricing(for: connection, modelID: id),
            isEnabled: Binding(
                get: { false },
                set: { enabled in
                    guard enabled else { return }
                    if let catalog,
                        (try? ProviderConnectionTestModel(catalog: catalog, connection: connection))?.canTest(
                            with: connection) == true
                    {
                        Task { await model.addCatalogModel(catalog, connection: connection) }
                    } else {
                        editModel(nil, connection: connection, modelID: id)
                    }
                })
        )
        .disabled(!connection.isEnabled || model.isWorking || model.container.isDemo)
        .contextMenu {
            Button("Configure") { editModel(nil, connection: connection, modelID: id) }
                .disabled(model.isWorking || model.container.isDemo)
        }
    }

    private func modelRow(
        id: String, name: String?, metadata: CatalogModelMetadata?, providerID: String?,
        publishedPricing: ModelPublishedPricing? = nil, contextWindow: Int? = nil,
        supportsVision: Bool? = nil, supportsTools: Bool? = nil, supportsThinking: Bool? = nil,
        isEnabled: Binding<Bool>
    ) -> some View {
        let pricing: MiraProviderModelRow.Pricing? = if let publishedPricing {
            .init(
                input: CostPresentation.amount(publishedPricing.inputMinimum, locale: locale) + "–"
                    + CostPresentation.amount(publishedPricing.inputMaximum, locale: locale),
                output: CostPresentation.amount(publishedPricing.outputMinimum, locale: locale) + "–"
                    + CostPresentation.amount(publishedPricing.outputMaximum, locale: locale),
                note: L10n.string("Off-peak–peak", locale: locale),
                detail: L10n.string("Peak hours: Mon–Fri 01:00–04:00 and 06:00–10:00 UTC. Other hours are off-peak.", locale: locale),
                sourceURL: URL(string: publishedPricing.sourceURL), checkedAt: publishedPricing.checkedAt)
        } else { metadata?.pricing.map {
            MiraProviderModelRow.Pricing(
                input: CostPresentation.amount($0.input, locale: locale),
                output: CostPresentation.amount($0.output, locale: locale))
        } }
        return MiraProviderModelRow(
            name: name ?? id, modelID: id, pricing: pricing, providerID: providerID,
            supportsVision: supportsVision ?? (metadata?.inputModalities.contains("image") == true),
            supportsTools: supportsTools ?? (metadata?.toolCall == true),
            supportsThinking: supportsThinking ?? (metadata?.reasoning == true),
            contextWindow: contextWindow ?? metadata?.contextWindow, isEnabled: isEnabled)
    }

    private var models: some View {
        Group {
            PurposeRoutingView(model: model)
            MiraSettingsSection {
                HStack {
                    Spacer()
                    Button("Manage Providers") { navigate(.category(.providers)) }
                        .buttonStyle(MiraSettingsButtonStyle())
                }
            }
        }
    }

    private func editModel(
        _ descriptor: AgentConfiguredModel?, connection: AgentConfiguredConnection, modelID: String = ""
    ) {
        model.cancelProbe()
        guard let library = model.container.library else { return }
        let preset = descriptor.flatMap { item in model.presets.first { $0.modelDescriptorID == item.id } }
        modelEditor = ModelEditorSelection(
            connection: connection, existing: descriptor, preset: preset, library: library, initialModelID: modelID)
    }

    private var hasModelFeedback: Bool { model.error != nil || model.statusKey != nil || model.probeObservation != nil }

    private var modelFeedback: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
            if let error = model.error {
                Text(L10n.error(error, locale: locale)).foregroundStyle(.red).textSelection(.enabled)
            } else if let key = model.statusKey {
                Text(L10n.string(key, locale: locale)).foregroundStyle(MiraTheme.Settings.secondaryText)
            }
            if model.probeObservation != nil {
                Button("Save Test Result") { Task { await model.saveProbeObservation() } }
                    .buttonStyle(MiraSettingsButtonStyle()).disabled(model.isWorking)
            }
            if model.isProbing {
                Button("Cancel Test") { model.cancelProbe() }.buttonStyle(MiraSettingsButtonStyle())
            }
        }
        .font(MiraTheme.Settings.caption)
        .accessibilityIdentifier("settings.provider.models.status")
    }
}
