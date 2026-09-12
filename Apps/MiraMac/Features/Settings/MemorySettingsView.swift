import SwiftUI
import MiraCore

@MainActor
struct MemorySettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: MemorySettingsModel
    let onManageModels: () -> Void

    private var modeSelectionBinding: Binding<String> {
        Binding(
            get: { model.mode.rawValue },
            set: { rawValue in
                guard let value = MemoryCaptureMode(rawValue: rawValue), model.mode != value else { return }
                model.mode = value
                model.markDirty()
            }
        )
    }

    private var tokenLimitBinding: Binding<String> {
        Binding(get: { model.dailyTokenLimitText }, set: {
            guard model.dailyTokenLimitText != $0 else { return }
            model.dailyTokenLimitText = $0
            model.markDirty()
        })
    }

    private var hasMemoryExtractionRoute: Bool {
        model.configuration.bindings.contains {
            $0.purpose == .memoryExtraction && isDisplayedScope($0.scope)
        }
    }

    var body: some View {
        MiraSettingsPage {
            Group {
                MiraSettingsSection("Automatic memory") {
                    MiraSettingsRow("Capture mode", subtitle: LocalizedStringKey(modeDescriptionKey(model.mode))) {
                        MiraSettingsSelect(
                            title: "Capture mode",
                            selection: modeSelectionBinding,
                            options: MemoryCaptureMode.allCases.map {
                                .init(id: $0.rawValue, title: LocalizedStringResource(stringLiteral: modeKey($0)))
                            },
                            identifier: "settings.memory.mode",
                            maximumWidth: MiraTheme.Layout.selectMaxWidth
                        )
                    }
                    .disabled(model.isSaving)

                    if model.mode != .manualOnly {
                        Text("Automatic capture uses extra tokens. Sensitive memories stay local.")
                            .font(MiraTheme.Settings.caption)
                            .foregroundStyle(MiraTheme.Settings.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if model.mode != .manualOnly && !hasMemoryExtractionRoute {
                        HStack(alignment: .firstTextBaseline, spacing: MiraTheme.Spacing.md) {
                            Text("Choose a memory extraction model in Models.")
                                .font(MiraTheme.Settings.caption)
                                .foregroundStyle(MiraTheme.Settings.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: MiraTheme.Spacing.sm)
                            Button("Models") { onManageModels() }
                                .buttonStyle(MiraSettingsButtonStyle())
                                .fixedSize()
                                .disabled(model.isSaving)
                        }
                    }
                }

                MiraSettingsSection("Daily extraction budget") {
                    MiraSettingsFormRow("Daily token limit", subtitle: "Daily token budget for automatic memory. Resets at 00:00 UTC.") {
                        TextField("Daily token limit", text: tokenLimitBinding)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isSaving)
                            .frame(width: 150)
                            .accessibilityIdentifier("settings.memory.tokenLimit")
                    }
                    if let budget = model.budget {
                        MiraSettingsRow("Remaining today") {
                            Text(L10n.format("%lld", locale: locale, Int64(budget.remainingTokens)))
                        }
                    }
                    HStack {
                        if model.isSaving { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                        if model.isDirty {
                            Button("Discard Changes") { model.discardAndReload() }
                                .buttonStyle(MiraSettingsButtonStyle())
                                .disabled(model.isSaving)
                                .accessibilityIdentifier("settings.memory.discard")
                        }
                        Button("Save") { model.startSave() }
                            .buttonStyle(MiraSettingsButtonStyle(isPrimary: true))
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.isDirty || model.isSaving || model.container.isDemo)
                            .accessibilityIdentifier("settings.memory.save")
                    }
                    .controlSize(.small)

                    if let key = model.statusKey {
                        Text(L10n.string(key, locale: locale))
                            .font(MiraTheme.Settings.body)
                            .foregroundStyle(MiraTheme.Settings.secondaryText)
                    }
                    if let error = model.error {
                        Text(L10n.error(error, locale: locale))
                            .font(MiraTheme.Settings.body)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let startupError = model.container.startupError {
                        Text(L10n.error(startupError, locale: locale))
                            .font(MiraTheme.Settings.body)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .task { await model.observe() }
    }

    private func isDisplayedScope(_ scope: RouteScope) -> Bool {
        switch scope {
        case .global, .workspace: true
        case .conversation: false
        }
    }

    private func modeKey(_ value: MemoryCaptureMode) -> String {
        switch value {
        case .manualOnly: "Manual only"
        case .candidateOnly: "Candidate review"
        case .automaticWithUndo: "Automatic with undo"
        }
    }

    private func modeDescriptionKey(_ value: MemoryCaptureMode) -> String {
        switch value {
        case .manualOnly: "Only memories you save or approve are stored."
        case .candidateOnly: "New memories wait for your review."
        case .automaticWithUndo: "Eligible memories are saved automatically."
        }
    }
}
