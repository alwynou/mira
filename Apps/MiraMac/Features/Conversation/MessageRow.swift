import SwiftUI
import MiraCore

struct MessageRow: View {
    let role: SessionMessageRole
    let text: String
    let status: ExecutionStatus?

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                if let status, status != .completed {
                    Text("Incomplete").font(MiraTheme.Typography.caption).foregroundStyle(.orange)
                }
                Text(verbatim: text)
                    .font(MiraTheme.Typography.body)
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, MiraTheme.Spacing.lg)
            .padding(.vertical, MiraTheme.Spacing.md)
            .background(MiraTheme.Colors.inset, in: .rect(cornerRadius: MiraTheme.Radius.panel))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You")
    }
}
