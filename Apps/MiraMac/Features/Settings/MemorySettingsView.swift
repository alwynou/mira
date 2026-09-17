import MiraCore
import SwiftUI

@MainActor
struct MemorySettingsView: View {
    @Environment(\.miraSettingsPageActive) private var isActive
    @Environment(\.locale) private var locale
    @Bindable var model: MemorySettingsModel

    var body: some View {
        MiraSettingsPage {
            Group {
                MiraSettingsSection("Automatic memory") {
                    MiraSettingsRow(
                        "Background extraction",
                        subtitle: "Mira saves useful memories automatically after several turns or a pause, using the conversation’s model."
                    ) {
                        Text("Automatic")
                            .foregroundStyle(MiraTheme.Settings.secondaryText)
                    }
                    MiraSettingsRow(
                        "Extraction model",
                        subtitle: "Extraction reuses the current conversation model and its cached prefix when possible. Sensitive memories stay local."
                    ) {
                        Text("Uses the current conversation model")
                            .foregroundStyle(MiraTheme.Settings.secondaryText)
                    }
                    Text("Mira automatically extracts useful memories after a few turns or a pause, without asking each time.")
                        .font(MiraTheme.Settings.caption)
                        .foregroundStyle(MiraTheme.Settings.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                MiraSettingsSection("Local memory search") {
                    MiraSettingsRow("Embedding model", subtitle: "Memories are indexed on this Mac. No embedding API key is needed.") {
                        Text(verbatim: "Qwen3 · 0.6B · 4-bit")
                            .foregroundStyle(MiraTheme.Settings.secondaryText)
                    }
                    MiraSettingsRow("Status") {
                        switch model.localModelStatus {
                        case .ready:
                            Text("Ready for semantic search")
                        case .installing:
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Preparing local model…")
                            }
                        case .unavailable, .failed:
                            Button("Prepare local model") { model.prepareLocalModel() }
                                .buttonStyle(MiraSettingsButtonStyle())
                                .disabled(model.container.isDemo)
                        }
                    }
                    if case .failed = model.localModelStatus {
                        Text("The local model is unavailable. Keyword search remains available. Try preparing the model again.")
                            .font(MiraTheme.Settings.caption)
                            .foregroundStyle(MiraTheme.Settings.secondaryText)
                    }
                }

                if let error = model.error {
                    MiraSettingsSection("Memory status") {
                        Text(L10n.error(error, locale: locale))
                            .font(MiraTheme.Settings.body)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                if let startupError = model.container.startupError {
                    MiraSettingsSection("Startup status") {
                        Text(L10n.error(startupError, locale: locale))
                            .font(MiraTheme.Settings.body)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .task(id: isActive) {
            if isActive { await model.observe() } else { await model.stop() }
        }
        .onDisappear { Task { await model.stop() } }
    }
}
