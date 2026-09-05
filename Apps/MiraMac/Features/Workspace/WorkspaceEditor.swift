import SwiftUI
import MiraCore

struct WorkspaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    let application: MiraApplication
    let workspace: Workspace?
    @State private var name = ""
    @State private var background = ""
    @State private var allowsRemoteSend = true
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(workspace == nil ? "创建工作空间" : "编辑工作空间").font(.title2.weight(.semibold))
            TextField("名称", text: $name)
            VStack(alignment: .leading, spacing: 8) {
                Text("项目背景").font(.headline)
                Text("允许发送时，这段背景会随当前工作空间的对话一起发给所选模型。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $background).font(.body).frame(height: 150).border(.quaternary).accessibilityLabel("项目背景")
            }
            Toggle("允许发送此工作空间的对话和背景到模型服务", isOn: $allowsRemoteSend)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        } catch { self.error = MiraError.safe(error).message }
    }
}
