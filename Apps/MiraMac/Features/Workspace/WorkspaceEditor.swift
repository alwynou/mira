import MiraCore
import SwiftUI

struct WorkspaceEditor: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let workspaces: WorkspaceApplication
    let settings: any MacModelSettings
    let workspace: Workspace?
    @State private var model: WorkspaceEditorModel

    init(workspaces: WorkspaceApplication, settings: any MacModelSettings, workspace: Workspace?) {
        self.workspaces = workspaces
        self.settings = settings
        self.workspace = workspace
        _model = State(
            initialValue: WorkspaceEditorModel(
                workspaces: workspaces, settings: settings, workspace: workspace))
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.string(workspace == nil ? "Create workspace" : "Edit workspace", locale: locale)).font(
                .title2.weight(.semibold))
            TextField("Name", text: $model.name)
            VStack(alignment: .leading, spacing: 8) {
                Text("Project background").font(.headline)
                Text(
                    "When sending is allowed, this background is sent with conversations in this workspace to the selected model."
                ).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.background).font(.body).frame(height: 150).border(.quaternary)
                    .accessibilityLabel("Project background")
            }
            Toggle(
                "Allow this workspace's conversations and background to be sent to the model service",
                isOn: $model.allowsRemoteSend)
            Toggle("Restrict provider connections", isOn: $model.restrictConnections)
                .disabled(!model.allowsRemoteSend)
            if model.restrictConnections {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.connections) { connection in
                            Toggle(
                                isOn: Binding(
                                    get: { model.allowedConnections.contains(connection.id) },
                                    set: { enabled in
                                        if enabled {
                                            model.allowedConnections.insert(connection.id)
                                        } else {
                                            model.allowedConnections.remove(connection.id)
                                        }
                                    })
                            ) { Text(verbatim: connection.name) }
                        }
                        if model.connections.isEmpty {
                            Text("No provider connections configured.").foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120).disabled(!model.allowsRemoteSend)
                Text(
                    "Only selected connections may receive this workspace's content. Selecting none blocks all connections."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(L10n.error(error, locale: locale)).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.dismiss()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await model.save() { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSaving || model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 520)
        .task { await model.loadConnections() }
        .onDisappear { model.invalidatePresentation() }
    }
}
