import SwiftUI
import MiraCore

struct WorkspaceEditor: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let application: MiraApplication
    let workspace: Workspace?
    @State private var name = ""
    @State private var background = ""
    @State private var allowsRemoteSend = true
    @State private var error: MiraError?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.string(workspace == nil ? "Create workspace" : "Edit workspace", locale: locale)).font(.title2.weight(.semibold))
            TextField("Name", text: $name)
            VStack(alignment: .leading, spacing: 8) {
                Text("Project background").font(.headline)
                Text("When sending is allowed, this background is sent with conversations in this workspace to the selected model.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $background).font(.body).frame(height: 150).border(.quaternary).accessibilityLabel("Project background")
            }
            Toggle("Allow this workspace's conversations and background to be sent to the model service", isOn: $allowsRemoteSend)
            if let error { Text(L10n.error(error, locale: locale)).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 520)
            .onAppear { name = workspace?.name ?? ""; background = workspace?.background ?? ""; allowsRemoteSend = workspace?.allowsRemoteSend ?? true }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            if var updated = workspace {
                updated.name = name; updated.background = background; updated.allowsRemoteSend = allowsRemoteSend
                try await application.updateWorkspace(updated)
            } else { try await application.createWorkspace(name: name, background: background, allowsRemoteSend: allowsRemoteSend) }
            dismiss()
        } catch { self.error = MiraError.safe(error) }
    }
}
