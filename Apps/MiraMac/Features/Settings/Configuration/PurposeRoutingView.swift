import SwiftUI
import MiraCore

private enum RoutingScopeChoice: Hashable {
    case global
    case workspace(WorkspaceID)
    case conversation(ConversationID)

    var id: String {
        switch self {
        case .global: "global" // i18n-verbatim: Stable route-scope selection identifier.
        case .workspace(let id): "workspace-\(id.rawValue.uuidString)"
        case .conversation(let id): "conversation-\(id.rawValue.uuidString)"
        }
    }

    var routeScope: RouteScope {
        switch self {
        case .global: .global
        case .workspace(let id): .workspace(id)
        case .conversation(let id): .conversation(id)
        }
    }
}

struct PurposeRoutingView: View {
    @Environment(\.locale) private var locale
    let configuration: ModelConfiguration
    let workspaces: [Workspace]
    let conversations: [Conversation]
    let container: AppContainer
    let onChange: () async -> Void
    @State private var scope: RoutingScopeChoice = .global

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            if scopeChoices.count > 1 {
                MiraSettingsSection {
                    MiraSettingsRow("Applies to") {
                        MiraSettingsSelect(title: "Applies to", selection: Binding(
                            get: { scope.id },
                            set: { value in
                                if let choice = scopeChoices.first(where: { $0.scope.id == value }) { scope = choice.scope }
                            }), options: scopeChoices.map { .init(id: $0.scope.id, title: $0.title) },
                            identifier: "settings.models.scope", maximumWidth: 240)
                    }
                }
            }
            ForEach([ModelPurpose.conversation, .memoryExtraction], id: \.self) { purpose in
                PurposeModelCard(configuration: configuration, container: container,
                                 purpose: purpose, scope: scope.routeScope, onChange: onChange)
                    .id(scope)
            }
        }
    }

    private var scopeChoices: [(scope: RoutingScopeChoice, title: LocalizedStringResource)] {
        var choices: [(scope: RoutingScopeChoice, title: LocalizedStringResource)] = [(.global, "Global")]
        choices += workspaces.map { (.workspace($0.id), "Workspace: \($0.name)") }
        choices += conversations.map { conversation in
            let title = conversation.title.isEmpty ? L10n.string("Untitled conversation", locale: locale) : conversation.title
            return (.conversation(conversation.id), "Conversation: \(title)")
        }
        return choices
    }
}

private struct PurposeModelCard: View {
    @Environment(\.locale) private var locale
    let configuration: ModelConfiguration
    let container: AppContainer
    let purpose: ModelPurpose
    let scope: RouteScope
    let onChange: () async -> Void
    @State private var routeID: RouteID?
    @State private var loadedBinding: RouteBinding?
    @State private var error: MiraError?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            MiraSettingsSection {
                MiraSettingsRow(purpose == .conversation ? "Conversation model" : "Memory extraction model",
                                subtitle: purpose == .conversation ? "Used for new conversations." : "Used to organize memories in the background.") {
                    MiraSettingsSelect(title: "Model", selection: Binding(
                        get: { routeID?.rawValue.uuidString ?? "" },
                        set: { value in
                            if value.isEmpty { routeID = nil }
                            else if let entry = eligibleModels.first(where: { $0.route.id.rawValue.uuidString == value }) {
                                routeID = entry.route.id
                            }
                            error = nil
                        }), options: modelOptions, identifier: "settings.models.default.\(purpose.rawValue)",
                        placeholder: "Select a model", clearSelectionTitle: scope == .global ? "Clear Selection" : "Use Inherited Model",
                        minimumWidth: 160, maximumWidth: 240)
                        .disabled(saving)
                }
                if eligibleModels.isEmpty {
                    Text("Configure a compatible model in Providers.")
                        .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                }
            }
            if hasChanges || saving {
                HStack {
                    if saving { ProgressView().controlSize(.small) }
                    Spacer()
                    if hasChanges {
                        Button("Discard Changes") { loadBinding() }
                            .buttonStyle(MiraSettingsButtonStyle()).disabled(saving)
                    }
                    Button("Save") { saveBinding() }
                        .buttonStyle(MiraSettingsButtonStyle(isPrimary: true))
                        .disabled(saving || container.isDemo || !selectionAvailable || !hasChanges)
                }
            }
            if let error {
                Text(L10n.error(error, locale: locale))
                    .font(MiraTheme.Typography.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onAppear { loadBinding() }
        .onChange(of: configuration.bindings) { _, _ in
            if !hasChanges && !saving { loadBinding() }
        }
    }

    private var eligibleModels: [ModelPoolEntry] {
        configuration.models(for: purpose == .conversation ? .conversation : .memoryExtraction)
    }

    private var modelOptions: [MiraSettingsSelect.Option] {
        var options: [MiraSettingsSelect.Option] = []
        if let routeID, !eligibleModels.contains(where: { $0.route.id == routeID }) {
            options.append(.init(id: routeID.rawValue.uuidString, title: "Unavailable model"))
        }
        options += eligibleModels.map { entry in
            let name = entry.model.catalogMetadata?.displayName ?? entry.model.modelID
            return .init(id: entry.route.id.rawValue.uuidString, verbatimTitle: "\(name) · \(entry.connection.name)")
        }
        return options
    }

    private var hasChanges: Bool { routeID != loadedBinding?.routeID }
    private var selectionAvailable: Bool { routeID.map { id in eligibleModels.contains { $0.route.id == id } } ?? true }
    private var currentBinding: RouteBinding? { configuration.bindings.first { $0.scope == scope && $0.purpose == purpose } }

    private func loadBinding() {
        loadedBinding = currentBinding
        routeID = loadedBinding?.routeID
        error = nil
    }

    private func saveBinding() {
        guard hasChanges, !saving, !container.isDemo, let application = container.application else { return }
        guard selectionAvailable else { error = MiraError(.configuration, "Choose an available model from your pool."); return }
        let targetScope = scope
        let targetPurpose = purpose
        let selectedRouteID = routeID
        let originalBinding = loadedBinding
        let expectedRevision = originalBinding?.revision
        saving = true
        error = nil
        Task { @MainActor in
            do {
                if let selectedRouteID {
                    let binding = RouteBinding(scope: targetScope, purpose: targetPurpose, routeID: selectedRouteID, revision: (expectedRevision ?? 0) + 1)
                    try await application.saveRouteBinding(binding, expectedRevision: expectedRevision)
                    loadedBinding = binding
                    routeID = selectedRouteID
                } else if let originalBinding {
                    try await application.removeRouteBinding(originalBinding)
                    loadedBinding = nil
                    routeID = nil
                }
                await onChange()
                saving = false
            } catch {
                saving = false
                self.error = MiraError.safe(error)
            }
        }
    }
}
