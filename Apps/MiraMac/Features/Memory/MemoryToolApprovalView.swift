import SwiftUI
import MiraCore

/// A host-owned decision surface bound to an immutable tool proposal.
struct MemoryToolApprovalView: View {
    @Environment(\.locale) private var locale
    let request: MemoryApprovalRequest
    let application: MiraApplication
    let workspaces: [Workspace]
    @State private var responding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review memory request", systemImage: "brain").font(.headline)
            Text("The assistant proposes saving this memory. Review its content, source, and scope before allowing it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory content").font(.caption.weight(.semibold))
                    ScrollView { Text(verbatim: request.draft.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original user excerpt").font(.caption.weight(.semibold))
                    ScrollView { Text(verbatim: request.evidenceExcerpt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.frame(maxHeight: 100)
            HStack {
                if let workspaceID = request.draft.scope.workspaceID {
                    LabeledContent("Workspace") {
                        Text(verbatim: workspaces.first(where: { $0.id == workspaceID })?.name ?? workspaceID.rawValue.uuidString)
                    }
                } else { Label("Global memory", systemImage: "globe") }
                Label(LocalizedStringKey(request.draft.allowsRemoteUse ? "May be included in future model requests" : "Local only"), systemImage: request.draft.allowsRemoteUse ? "network" : "lock")
                Spacer()
                Button("Deny") { respond(false) }.disabled(responding)
                Button("Save memory") { respond(true) }.buttonStyle(.borderedProminent).disabled(responding)
            }.font(.caption)
        }
        .padding(18).background(.regularMaterial)
        .onChange(of: request.id) { _, _ in responding = false }
    }
    private func respond(_ approved: Bool) {
        responding = true
        let id = request.id
        Task { await application.respondToMemoryApproval(id, approved: approved) }
    }
}
