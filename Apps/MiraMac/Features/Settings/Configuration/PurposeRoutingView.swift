import SwiftUI
import MiraCore

private enum RoutingScopeChoice: Hashable {
    case global
    case workspace(WorkspaceID)
    case conversation(ConversationID)

    var routeScope: RouteScope {
        switch self {
        case .global: .global
        case .workspace(let id): .workspace(id)
        case .conversation(let id): .conversation(id)
        }
    }
}

struct PurposeRoutingView: View {
    let configuration: ModelConfiguration
    let workspaces: [Workspace]
    let conversations: [Conversation]
    let container: AppContainer
    let onChange: () async -> Void
    @State private var scope: RoutingScopeChoice = .global

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            MiraSettingsSection {
                MiraSettingsRow("Scope") {
                    Picker("Scope", selection: $scope) {
                        Text("Global").tag(RoutingScopeChoice.global)
                        if !workspaces.isEmpty {
                            Section("Workspaces") {
                                ForEach(workspaces) { Text(verbatim: $0.name).tag(RoutingScopeChoice.workspace($0.id)) }
                            }
                        }
                        if !conversations.isEmpty {
                            Section("Conversations") {
                                ForEach(conversations) { conversation in
                                    Group {
                                        if conversation.title.isEmpty { Text("Untitled conversation") }
                                        else { Text(verbatim: conversation.title) }
                                    }.tag(RoutingScopeChoice.conversation(conversation.id))
                                }
                            }
                        }
                    }.labelsHidden().frame(maxWidth: 300)
                        .accessibilityIdentifier("settings.models.scope")
                }
            }
            ForEach([ModelPurpose.conversation, .memoryExtraction], id: \.self) { purpose in
                PurposeModelCard(configuration: configuration, container: container,
                                 purpose: purpose, scope: scope.routeScope, onChange: onChange)
                    .id(scope)
            }
            Text("Adding a model to the pool does not select it for any purpose. Removing a local selection uses the workspace or global default when configured.")
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
        }
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
    @State private var statusKey: String?
    @State private var saving = false

    var body: some View {
        MiraSettingsSection {
            Text(LocalizedStringKey(purpose == .conversation ? "Conversation" : "Memory Extraction"))
                .font(MiraTheme.Typography.body.weight(.semibold))
            Text(LocalizedStringKey(purpose == .conversation
                ? "Conversation models need streaming text and valid token limits. Agent tools also need tool-call capability."
                : "Memory extraction needs streaming text, valid token limits, and a separate JSON extraction declaration. Native structured output is optional."))
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            Menu {
                Picker("Model", selection: $routeID) {
                    Text("Inherit / no binding").tag(nil as RouteID?)
                    if let routeID, !eligibleModels.contains(where: { $0.route.id == routeID }) {
                        Text("Unavailable model").tag(Optional(routeID))
                    }
                    ForEach(eligibleModels) { entry in
                        Text(verbatim: "\(entry.model.modelID) · \(entry.connection.name)").tag(Optional(entry.route.id))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack {
                    selectionLabel
                    Spacer()
                    Image(systemName: "chevron.down").font(MiraTheme.Typography.caption)
                }
                .padding(MiraTheme.Spacing.md)
                .background(MiraTheme.Colors.surface, in: .rect(cornerRadius: MiraTheme.Radius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: MiraTheme.Radius.small)
                        .strokeBorder(MiraTheme.Colors.border, lineWidth: 1)
                }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(saving)
            .accessibilityLabel(Text("Model"))
            .accessibilityIdentifier("settings.models.default.\(purpose.rawValue)")
            if eligibleModels.isEmpty {
                Text("No models are ready for this purpose. Configure capabilities in the model pool.")
                    .font(MiraTheme.Typography.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Use Inherited Model", role: .destructive) { removeBinding() }
                    .disabled(saving || container.isDemo || loadedBinding == nil)
                Spacer()
                Button("Save Selection") { saveBinding() }
                    .buttonStyle(MiraPrimaryButtonStyle())
                    .disabled(saving || container.isDemo || !selectionAvailable || (routeID == nil && loadedBinding == nil))
            }
            if let error { Text(L10n.error(error, locale: locale)).font(MiraTheme.Typography.caption).foregroundStyle(.red) }
            if let statusKey { Text(L10n.string(statusKey, locale: locale)).font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText) }
        }
        .onAppear { loadBinding() }
        .onChange(of: scope) { _, _ in loadBinding() }
        .onChange(of: configuration.bindings) { _, _ in loadBinding() }
    }

    private var eligibleModels: [ModelPoolEntry] {
        configuration.models(for: purpose == .conversation ? .conversation : .memoryExtraction)
    }

    @ViewBuilder private var selectionLabel: some View {
        if let routeID {
            if let entry = eligibleModels.first(where: { $0.route.id == routeID }) {
                Text(verbatim: "\(entry.model.modelID) · \(entry.connection.name)").lineLimit(1)
            } else { Text("Unavailable model") }
        } else { Text("Inherit / no binding") }
    }

    private var selectionAvailable: Bool { routeID.map { id in eligibleModels.contains { $0.route.id == id } } ?? true }
    private var currentRouteScope: RouteScope { scope }
    private var currentBinding: RouteBinding? { configuration.bindings.first { $0.scope == currentRouteScope && $0.purpose == purpose } }
    private func loadBinding() {
        loadedBinding = currentBinding
        routeID = loadedBinding?.routeID
        error = nil
        statusKey = nil
    }
    private func saveBinding() {
        guard let application = container.application else { return }
        guard selectionAvailable else { error = MiraError(.configuration, "Choose an available model from your pool."); return }
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
