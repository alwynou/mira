import SwiftUI
import MiraCore

@MainActor
struct MemorySettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: MemorySettingsModel

    private var modeBinding: Binding<MemoryCaptureMode> {
        Binding(get: { model.mode }, set: {
            guard model.mode != $0 else { return }
            model.mode = $0
            model.markDirty()
        })
    }
    private var tokenLimitBinding: Binding<String> {
        Binding(get: { model.dailyTokenLimitText }, set: {
            guard model.dailyTokenLimitText != $0 else { return }
            model.dailyTokenLimitText = $0
            model.markDirty()
        })
    }

    var body: some View {
        MiraSettingsPage {
            MiraSettingsHeader(title: "Memory", subtitle: "Configure automatic memory and daily extraction limits.")
            MiraSettingsSection("Automatic memory") {
                MiraSettingsRow("Capture mode") {
                    Picker("Capture mode", selection: modeBinding) {
                        ForEach(MemoryCaptureMode.allCases, id: \.self) { value in
                            Text(L10n.string(modeKey(value), locale: locale)).tag(value)
                        }
                    }.labelsHidden().accessibilityIdentifier("settings.memory.mode")
                }.disabled(model.isSaving)
                Text(L10n.string(modeDescriptionKey(model.mode), locale: locale)).font(MiraTheme.Typography.body).foregroundStyle(MiraTheme.Colors.secondaryText)
                MiraSettingsDivider()
                Text("Automatic capture uses a dedicated memory-extraction route. It may make additional model requests and use additional tokens. Nonsensitive memories can be recalled in later conversations when policy and routing allow.").font(MiraTheme.Typography.body).foregroundStyle(MiraTheme.Colors.secondaryText)
                Text("Sensitive memories remain local-only. Candidates require review before they enter recall.").font(MiraTheme.Typography.body).foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            MiraSettingsSection("Daily extraction budget") {
                MiraSettingsRow("Daily token limit", subtitle: "This limit is shared by memory extraction attempts and resets at the start of each UTC day. It is a token budget, not a provider billing guarantee.") {
                    TextField("Daily token limit", text: tokenLimitBinding).textFieldStyle(.roundedBorder).disabled(model.isSaving).frame(width: 150).accessibilityIdentifier("settings.memory.tokenLimit")
                }
            }
            if let budget = model.budget {
                MiraSettingsSection("UTC usage") {
                    MiraSettingsRow("Token limit") { Text(L10n.format("%lld", locale: locale, Int64(budget.tokenLimit))) }
                    MiraSettingsRow("Reserved") { Text(L10n.format("%lld", locale: locale, Int64(budget.reservedTokens))) }
                    MiraSettingsRow("Charged") { Text(L10n.format("%lld", locale: locale, Int64(budget.chargedTokens))) }
                    MiraSettingsRow("Remaining") { Text(L10n.format("%lld", locale: locale, Int64(budget.remainingTokens))) }
                }
            }
            MiraSettingsSection("Memory extraction route") {
                extractionRouteView
                MiraSettingsDivider()
                Text("Configure the dedicated route in Models > Purpose Defaults. Mira never falls back to a conversation route for memory extraction.").font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            MiraSettingsSection {
                HStack {
                    if model.isDirty { Text("Unsaved changes").font(MiraTheme.Typography.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button("Reload settings") { model.discardAndReload() }.disabled(model.isSaving)
                    Button("Save") { model.startSave() }.buttonStyle(MiraPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!model.isDirty || model.isSaving || model.container.isDemo)
                }
                if let key = model.statusKey { Text(L10n.string(key, locale: locale)).font(MiraTheme.Typography.body).foregroundStyle(MiraTheme.Colors.secondaryText) }
                if let error = model.error { Text(L10n.error(error, locale: locale)).font(MiraTheme.Typography.body).foregroundStyle(.red).textSelection(.enabled) }
                if model.container.isDemo { Text("Demo mode: automatic-memory settings are read-only and no extraction requests are made.").font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText) }
                if let startupError = model.container.startupError { Text(L10n.error(startupError, locale: locale)).font(MiraTheme.Typography.body).foregroundStyle(.red).textSelection(.enabled) }
            }
        }.task { await model.observe() }
    }

    private var extractionRouteView: some View {
        let bindings = model.configuration.bindings.filter { $0.purpose == .memoryExtraction && isDisplayedScope($0.scope) }
        return Group {
            if bindings.isEmpty { Text("No dedicated memory-extraction route is configured.").foregroundStyle(MiraTheme.Colors.secondaryText) }
            else { VStack(alignment: .leading, spacing: 8) { ForEach(bindings) { binding in routeBindingRow(binding) } } }
        }
    }
    private func isDisplayedScope(_ scope: RouteScope) -> Bool { switch scope { case .global, .workspace: true; case .conversation: false } }
    private func routeBindingRow(_ binding: RouteBinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            scopeView(binding.scope).frame(minWidth: 140, alignment: .leading)
            if let route = model.configuration.routes.first(where: { $0.id == binding.routeID }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: route.name)
                    if let descriptor = model.configuration.models.first(where: { $0.id == route.modelDescriptorID }) {
                        if let connection = model.configuration.connections.first(where: { $0.id == descriptor.connectionID }) {
                            Text(verbatim: "\(connection.name) · \(descriptor.modelID)").font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                        } else {
                            Text(L10n.string("Connection unavailable", locale: locale)).font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                        }
                    } else {
                        Text(L10n.string("Model unavailable", locale: locale)).font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                    }
                }
            } else { Text(L10n.string("Route unavailable", locale: locale)).foregroundStyle(MiraTheme.Colors.secondaryText) }
            Spacer()
        }.padding(.vertical, 2)
    }
    @ViewBuilder private func scopeView(_ scope: RouteScope) -> some View {
        switch scope {
        case .global: Text("Global")
        case .workspace(let id): if let workspace = model.workspaces.first(where: { $0.id == id }) { Text(verbatim: workspace.name) } else { Text(L10n.string("Workspace unavailable", locale: locale)) }
        case .conversation: Text("Conversation")
        }
    }
    private func modeKey(_ value: MemoryCaptureMode) -> String {
        switch value { case .manualOnly: "Manual only"; case .candidateOnly: "Candidate review"; case .automaticWithUndo: "Automatic with undo" }
    }
    private func modeDescriptionKey(_ value: MemoryCaptureMode) -> String {
        switch value { case .manualOnly: "Only memories you create or approve manually are stored."; case .candidateOnly: "Eligible captures become candidates for your review; nothing enters recall automatically."; case .automaticWithUndo: "Conservative eligible captures may become active, with edit, archive, remove, and forget controls." }
    }
}
