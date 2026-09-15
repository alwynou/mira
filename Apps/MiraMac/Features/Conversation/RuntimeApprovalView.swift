import MiraCore
import SwiftUI

/// A generic, host-owned approval surface. The prompt is already composed by the
/// runtime and is displayed verbatim; this view does not interpret tool-specific
/// content or create an approval decision on its own.
struct RuntimeApprovalView: View {
    @Environment(\.locale) private var locale
    let request: RuntimeApprovalRequest
    let respond: @MainActor (RuntimeApprovalDecision) async -> Void

    @State private var respondingIdentity: RequestIdentity?
    @State private var now = Date()

    private struct RequestIdentity: Equatable {
        let id: UUID
        let proposalHash: String
        let authorizationEpoch: UInt64
        let expiresAt: Date
        let prompt: String

        init(_ request: RuntimeApprovalRequest) {
            id = request.id
            proposalHash = request.proposalHash
            authorizationEpoch = request.authorizationEpoch
            expiresAt = request.expiresAt
            prompt = request.prompt
        }
    }

    private var identity: RequestIdentity { .init(request) }
    private var isExpired: Bool { now >= request.expiresAt }
    private var isResponding: Bool { respondingIdentity == identity }

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            Label("Review tool request", systemImage: "checkmark.shield")
                .font(.headline)

            ScrollView {
                Text(verbatim: request.prompt)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(MiraTheme.Spacing.md)
            }
            .frame(minHeight: 96, maxHeight: 220)
            .background(MiraTheme.Colors.inset)
            .clipShape(.rect(cornerRadius: MiraTheme.Radius.small))

            HStack(spacing: MiraTheme.Spacing.sm) {
                Label("Expires", systemImage: isExpired ? "exclamationmark.triangle" : "clock")
                Text(request.expiresAt, style: .relative)
                    .foregroundStyle(isExpired ? .red : .secondary)
                Spacer()
                Button("Deny", role: .cancel) { submit(.denied) }
                    .disabled(isResponding || isExpired)
                Button("Allow") { submit(.approved) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isResponding || isExpired)
            }
            .font(.caption)
        }
        .padding(MiraTheme.Spacing.lg)
        .background(.regularMaterial)
        .onChange(of: request) { _, _ in
            respondingIdentity = nil
            now = Date()
        }
        .task(id: identity) {
            while !Task.isCancelled {
                let remaining = request.expiresAt.timeIntervalSinceNow
                guard remaining > 0 else {
                    now = Date()
                    return
                }
                do {
                    let milliseconds = Int64(min(250, max(1, Int(remaining * 1_000))))
                    try await Task.sleep(for: .milliseconds(milliseconds))
                } catch {
                    return
                }
                now = Date()
            }
        }
    }

    private func submit(_ decision: RuntimeApprovalDecision) {
        guard !isExpired, respondingIdentity != identity else { return }
        let submittedIdentity = identity
        respondingIdentity = submittedIdentity
        let responder = respond
        Task { @MainActor in
            await responder(decision)
            if respondingIdentity == submittedIdentity {
                respondingIdentity = nil
            }
        }
    }
}
