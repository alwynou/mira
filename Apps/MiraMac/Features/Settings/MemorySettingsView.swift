import SwiftUI
import MiraCore

@MainActor
struct MemorySettingsView: View {
    @Environment(\.locale) private var locale
    let container: AppContainer

    @State private var mode: MemoryCaptureMode = .manualOnly
    @State private var dailyTokenLimitText = "10000"
    @State private var policyRevision = 1
    @State private var configuration = ModelConfiguration(connections: [], models: [], routes: [], bindings: [])
    @State private var workspaces: [Workspace] = []
    @State private var budget: MemoryExtractionBudget?
    @State private var isDirty = false
    @State private var isSaving = false
    @State private var isApplying = false
    @State private var changeGeneration = 0
    @State private var saveTask: Task<Void, Never>?
    @State private var reloadTask: Task<Void, Never>?
    @State private var error: MiraError?
    @State private var statusKey: String?

    var body: some View {
        Form {
            Section {
                Picker("Capture mode", selection: modeBinding) {
                    ForEach(MemoryCaptureMode.allCases, id: \.self) { value in
                        Text(L10n.string(modeKey(value), locale: locale)).tag(value)
                    }
                }
                .disabled(isSaving)
                Text(L10n.string(modeDescriptionKey(mode), locale: locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Automatic capture uses a dedicated memory-extraction route. It may make additional model requests and use additional tokens. Nonsensitive memories can be recalled in later conversations when policy and routing allow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Sensitive memories remain local-only. Candidates require review before they enter recall.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Automatic memory")
            }

            Section {
                TextField("Daily token limit", text: tokenLimitBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)
                Text("This limit is shared by memory extraction attempts and resets at the start of each UTC day. It is a token budget, not a provider billing guarantee.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Daily extraction budget")
            }

            if let budget {
                Section("UTC usage") {
                    LabeledContent("Token limit") { Text(L10n.format("%lld", locale: locale, Int64(budget.tokenLimit))) }
                    LabeledContent("Reserved") { Text(L10n.format("%lld", locale: locale, Int64(budget.reservedTokens))) }
                    LabeledContent("Charged") { Text(L10n.format("%lld", locale: locale, Int64(budget.chargedTokens))) }
                    LabeledContent("Remaining") { Text(L10n.format("%lld", locale: locale, Int64(budget.remainingTokens))) }
                }
            }

            Section {
                extractionRouteView
                Text("Configure the dedicated route in Providers > Purpose Routing. Mira never falls back to a conversation route for memory extraction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Memory extraction route")
            }

            Section {
                HStack {
                    if isDirty { Text("Unsaved changes").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button("Reload settings") { discardAndReload() }
                        .disabled(isSaving)
                    Button("Save") {
                        let task = Task { @MainActor in
                            await save()
                            saveTask = nil
                        }
                        saveTask = task
                    }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isDirty || isSaving || container.isDemo)
                }
                if let statusKey { Text(L10n.string(statusKey, locale: locale)).font(.callout).foregroundStyle(.secondary) }
                if let error {
                    Text(L10n.error(error, locale: locale))
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if container.isDemo {
                    Text("Demo mode: automatic-memory settings are read-only and no extraction requests are made.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let startupError = container.startupError {
                    Text(L10n.error(startupError, locale: locale))
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task { await observeLibrary() }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            reloadTask?.cancel()
            reloadTask = nil
            changeGeneration += 1
        }
    }

    private var modeBinding: Binding<MemoryCaptureMode> {
        Binding(get: { mode }, set: { newValue in
            guard mode != newValue else { return }
            mode = newValue
            markDirty()
        })
    }

    private var tokenLimitBinding: Binding<String> {
        Binding(get: { dailyTokenLimitText }, set: { newValue in
            guard dailyTokenLimitText != newValue else { return }
            dailyTokenLimitText = newValue
            markDirty()
        })
    }

    private var extractionRouteView: some View {
        let bindings = configuration.bindings.filter { $0.purpose == .memoryExtraction && isDisplayedScope($0.scope) }
        return GroupBox {
            if bindings.isEmpty {
                Text("No dedicated memory-extraction route is configured.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(bindings) { binding in
                        routeBindingRow(binding)
                    }
                }
            }
        }
    }

    private func isDisplayedScope(_ scope: RouteScope) -> Bool {
        switch scope {
        case .global, .workspace: true
        case .conversation: false
        }
    }

    private func routeBindingRow(_ binding: RouteBinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            scopeView(binding.scope)
                .frame(minWidth: 140, alignment: .leading)
            if let route = configuration.routes.first(where: { $0.id == binding.routeID }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: route.name)
                    if let model = configuration.models.first(where: { $0.id == route.modelDescriptorID }) {
                        if let connection = configuration.connections.first(where: { $0.id == model.connectionID }) {
                            Text(verbatim: "\(connection.name) · \(model.modelID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L10n.string("Connection unavailable", locale: locale)).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(L10n.string("Model unavailable", locale: locale)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(L10n.string("Route unavailable", locale: locale)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func scopeView(_ scope: RouteScope) -> some View {
        switch scope {
        case .global:
            Text("Global")
        case .workspace(let id):
            if let workspace = workspaces.first(where: { $0.id == id }) {
                Text(verbatim: workspace.name)
            } else {
                Text(L10n.string("Workspace unavailable", locale: locale))
            }
        case .conversation:
            Text("Conversation")
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
        case .manualOnly: "Only memories you create or approve manually are stored."
        case .candidateOnly: "Eligible captures become candidates for your review; nothing enters recall automatically."
        case .automaticWithUndo: "Conservative eligible captures may become active, with edit, archive, remove, and forget controls."
        }
    }

    private func markDirty() {
        guard !isApplying else { return }
        isDirty = true
        changeGeneration += 1
        statusKey = nil
        error = nil
    }

    private func observeLibrary() async {
        guard let application = container.application else { return }
        await refreshIfClean()
        guard !Task.isCancelled else { return }
        let stream = await application.events()
        for await event in stream {
            guard !Task.isCancelled else { return }
            if case .changed = event { await refreshIfClean() }
        }
    }

    private func refreshIfClean() async {
        guard !isDirty, !isSaving else { return }
        await load(force: false)
    }

    private func load(force: Bool) async {
        guard let application = container.application else { return }
        let generation = changeGeneration
        do {
            let policy = try await application.memoryCapturePolicy()
            guard !Task.isCancelled, generation == changeGeneration, force || (!isDirty && !isSaving) else { return }
            apply(policy)
            let library = try await application.library(includeArchived: true)
            guard !Task.isCancelled, generation == changeGeneration, force || (!isDirty && !isSaving) else { return }
            configuration = library.configuration
            workspaces = library.workspaces
            let currentBudget = try await application.memoryExtractionBudget()
            guard !Task.isCancelled, generation == changeGeneration, force || (!isDirty && !isSaving) else { return }
            budget = currentBudget
            error = nil
        } catch {
            guard !Task.isCancelled, generation == changeGeneration else { return }
            self.error = MiraError.safe(error)
        }
    }

    private func apply(_ policy: MemoryCapturePolicy) {
        isApplying = true
        mode = policy.mode
        dailyTokenLimitText = String(policy.dailyTokenLimit)
        policyRevision = policy.revision
        isDirty = false
        isApplying = false
    }

    private func discardAndReload() {
        isDirty = false
        changeGeneration += 1
        let task = Task { @MainActor in
            await load(force: true)
            reloadTask = nil
        }
        reloadTask = task
    }

    private func save() async {
        guard !container.isDemo, let application = container.application else { return }
        let value = dailyTokenLimitText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let limit = Int(value), (1...10_000_000).contains(limit) else {
            error = MiraError(.invalidInput, "Enter a daily token limit from 1 to 10,000,000.")
            return
        }
        isSaving = true
        error = nil
        statusKey = nil
        do {
            try await application.saveMemoryCapturePolicy(mode: mode, dailyTokenLimit: limit, expectedRevision: policyRevision)
            guard !Task.isCancelled else {
                isSaving = false
                return
            }
            isDirty = false
            changeGeneration += 1
            statusKey = "Memory capture settings saved."
            await load(force: true)
        } catch {
            self.error = MiraError.safe(error)
            isDirty = true
        }
        isSaving = false
    }
}
