import MiraCore
import SwiftUI

private enum RoutingScopeChoice: Hashable {
    case global
    case workspace(WorkspaceID)

    var id: String {
        switch self {
        case .global: "global"  // i18n-verbatim: Stable route-scope selection identifier.
        case .workspace(let id): "workspace-\(id.rawValue.uuidString)"
        }
    }

    var routeScope: AgentRouteScope {
        switch self {
        case .global: .global
        case .workspace(let id): .workspace(id)
        }
    }
}

struct PurposeRoutingView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: ProviderLibraryModel
    @State private var scope: RoutingScopeChoice = .global

    var body: some View {
        Group {
            if scopeChoices.count > 1 {
                MiraSettingsSection {
                    MiraSettingsRow("Applies to") {
                        MiraSettingsSelect(
                            title: "Applies to",
                            selection: Binding(
                                get: { scope.id },
                                set: { value in
                                    if let choice = scopeChoices.first(where: { $0.scope.id == value }) {
                                        scope = choice.scope
                                    }
                                }), options: scopeChoices.map { .init(id: $0.scope.id, title: $0.title) },
                            identifier: "settings.models.scope", maximumWidth: 240)
                    }
                }
            }
            if let library = model.container.library {
                ForEach([AgentModelPurposeID.conversation, AgentModelPurposeID.memoryExtraction], id: \.self) {
                    purpose in
                    PurposeModelCard(library: library, providerModel: model, purpose: purpose, scope: scope.routeScope)
                        .id(scope)
                }
            }
            if model.hasMoreConversations {
                Button("Load More Conversations") { Task { await model.loadMoreConversations() } }
                    .buttonStyle(MiraSettingsButtonStyle()).disabled(model.isWorking)
            }
        }
    }

    private var scopeChoices: [(scope: RoutingScopeChoice, title: LocalizedStringResource)] {
        var choices: [(scope: RoutingScopeChoice, title: LocalizedStringResource)] = [(.global, "Global")]
        choices += model.workspaces.map { (.workspace($0.id), "Workspace: \($0.name)") }
        return choices
    }
}

private struct PurposeModelCard: View {
    @Environment(\.locale) private var locale
    @Bindable var providerModel: ProviderLibraryModel
    @State private var model: PurposeRoutingModel

    init(library: MacLibrary, providerModel: ProviderLibraryModel, purpose: String, scope: AgentRouteScope) {
        self.providerModel = providerModel
        #if DEBUG
            let readOnlyDemo = providerModel.container.isDemo && !ProcessInfo.processInfo.arguments.contains("--verify-model-selection")
        #else
            let readOnlyDemo = providerModel.container.isDemo
        #endif
        _model = State(
            initialValue: PurposeRoutingModel(
                scope: scope, purpose: purpose, library: library, isDemo: readOnlyDemo))
    }

    var body: some View {
        MiraSettingsSection {
            MiraSettingsRow(
                model.purpose == AgentModelPurposeID.conversation ? "Conversation model" : "Memory extraction model",
                subtitle: model.purpose == AgentModelPurposeID.conversation
                    ? "Used for new conversations." : "Used to organize memories in the background."
            ) {
                MiraSettingsSelect(
                    title: "Model",
                    selection: Binding(
                        get: { model.followsLastSelection ? "followLastSelection" : model.routeID?.rawValue.uuidString ?? "" },
                        set: { value in
                            model.followsLastSelection = value == "followLastSelection"
                            if !model.followsLastSelection {
                                model.routeID = model.options.first { $0.id.rawValue.uuidString == value }?.id
                            }
                        }
                    ),
                    options: modelOptions, identifier: "settings.models.default.\(model.purpose)",
                    placeholder: "Select a model",
                    clearSelectionTitle: model.scope == .global
                        ? (model.purpose == AgentModelPurposeID.conversation ? nil : "Clear Selection") : "Use Inherited Model",
                    maximumWidth: 240
                )
                .disabled(model.isSaving || model.isLoading)
            }
            if model.options.isEmpty {
                Text("Configure a compatible model in Providers.")
                    .font(MiraTheme.Settings.caption).foregroundStyle(MiraTheme.Settings.secondaryText)
            }
            if model.hasChanges || model.isSaving {
                HStack {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Discard Changes") { model.discardChanges() }
                        .buttonStyle(MiraSettingsButtonStyle()).disabled(model.isSaving)
                    Button("Save") { model.save { await providerModel.refresh() } }
                        .buttonStyle(MiraSettingsButtonStyle(isPrimary: true)).disabled(!model.canSave)
                }
            }
            if let error = model.error {
                Text(L10n.error(error, locale: locale))
                    .font(MiraTheme.Settings.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task(id: providerModel.revision) { await model.refresh(options: candidates) }
        .onDisappear { Task { await model.stop() } }
    }

    private var candidates: [PurposeRoutingOption] {
        providerModel.presets.compactMap { preset in
            guard let configured = providerModel.models.first(where: { $0.id == preset.modelDescriptorID }),
                let connection = providerModel.connections.first(where: { $0.id == configured.connectionID })
            else { return nil }
            return .init(id: preset.id, title: "\(configured.displayName ?? configured.modelID) · \(connection.name)")
        }
    }
    private var modelOptions: [MiraSettingsSelect.Option] {
        var options: [MiraSettingsSelect.Option] = []
        if model.purpose == AgentModelPurposeID.conversation {
            options.append(.init(id: "followLastSelection", title: "Follow last selected model"))
        }
        if let id = model.routeID, !model.options.contains(where: { $0.id == id }) {
            options.append(.init(id: id.rawValue.uuidString, title: "Unavailable model"))
        }
        options += model.options.map { .init(id: $0.id.rawValue.uuidString, verbatimTitle: $0.title) }
        return options
    }
}
