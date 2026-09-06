import SwiftUI
import MiraCore

private enum RoutingScopeChoice: Hashable { case global; case workspace(WorkspaceID); case conversation(ConversationID) }

struct PurposeRoutingView: View {
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
        ConfigurationSection(title: "Default Models", subtitle: "Choose a model from your pool for each purpose and scope. Background extraction requires its own explicit selection.") {
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
                Picker("Model", selection: Binding(get: { routeID }, set: { routeID = $0 })) {
                    Text("Inherit / no binding").tag(nil as RouteID?)
                    if let routeID, !eligibleModels.contains(where: { $0.route.id == routeID }) {
                        Text("Unavailable model").tag(Optional(routeID))
                    }
                    ForEach(eligibleModels) { entry in
                        Text(verbatim: "\(entry.model.modelID) · \(entry.connection.name)").tag(Optional(entry.route.id))
                    }
                }
            }.formStyle(.grouped).disabled(saving)
            Text(LocalizedStringKey(purpose == .conversation
                ? "Conversation models need streaming text and valid token limits. Agent tools also need tool-call capability."
                : "Memory extraction needs streaming text, valid token limits, and a separate JSON extraction declaration. Native structured output is optional."))
                .font(.caption).foregroundStyle(.secondary)
            if eligibleModels.isEmpty {
                Text("No models are ready for this purpose. Configure capabilities in the model pool.").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Save Selection") { saveBinding() }.buttonStyle(.borderedProminent).disabled(saving || container.isDemo || !selectionAvailable || (routeID == nil && loadedBinding == nil))
                Button("Use Inherited Model", role: .destructive) { removeBinding() }.disabled(saving || container.isDemo || loadedBinding == nil)
            }
            Text("Adding a model to the pool does not select it for any purpose. Removing a local selection uses the workspace or global default when configured.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red) }
            if let statusKey { Text(L10n.string(statusKey, locale: locale)).font(.callout).foregroundStyle(.secondary) }
            if container.isDemo { Text("Demo mode: configuration changes are disabled.").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { loadBinding() }
        .onChange(of: purpose) { _, _ in loadBinding() }
        .onChange(of: scope) { _, _ in loadBinding() }
        .onChange(of: configuration.bindings) { _, _ in loadBinding() }
    }

    private var eligibleModels: [ModelPoolEntry] {
        configuration.models(for: purpose == .conversation ? .conversation : .memoryExtraction)
    }

    private var selectionAvailable: Bool { routeID.map { id in eligibleModels.contains { $0.route.id == id } } ?? true }
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
