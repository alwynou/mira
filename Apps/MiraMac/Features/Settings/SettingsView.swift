import AppKit
import SwiftUI
import MiraCore
import MiraProviders

struct SettingsView: View {
    @Environment(\.locale) private var locale
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = ""
    let container: AppContainer
    @State private var routes: [ModelRoute] = []
    @State private var selectedID: RouteID?
    @State private var editing: ModelRoute?
    @State private var showEditor = false
    @State private var status = ""
    @State private var diagnostics: StorageDiagnostics?
    @State private var isWorking = false
    @State private var probeTask: Task<Void, Never>?
    @State private var restoredPath: String?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { generalSettings }
            Tab("Providers", systemImage: "network") { providerSettings }
            Tab("Data", systemImage: "externaldrive") { dataSettings }
        }.padding(20).frame(width: 780, height: 650)
            .task {
                guard let application = container.application else { return }
                for await _ in await application.events() {
                    if Task.isCancelled { return }
                    do { routes = try await application.library().routes; diagnostics = try await application.diagnostics() }
                    catch { status = MiraError.safe(error).message }
                }
            }
            .sheet(isPresented: $showEditor) { ProviderEditor(container: container, existing: editing).environment(\.locale, locale) }
            .onDisappear { probeTask?.cancel() }
    }

    private var generalSettings: some View {
        Form {
            Section("Language") {
                Picker("Display Language", selection: Binding(
                    get: { AppLanguage.resolve(stored: languagePreference) },
                    set: { languagePreference = $0.rawValue }
                )) {
                    Text("English").tag(AppLanguage.english)
                    Text("Chinese (Simplified)").tag(AppLanguage.simplifiedChinese)
                }
                Text("Changes apply immediately to all Mira windows and are saved for the next launch. Conversation content and model response language are not changed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("macOS manages the language of system menus and file dialogs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Your Models").font(.title2.weight(.semibold))
            Text("Supports OpenAI Chat Completions-compatible APIs and Anthropic Messages. API keys stay in this Mac's Keychain. Adding a connection does not send a test request.")
                .font(.callout).foregroundStyle(.secondary)
            List(selection: $selectedID) {
                ForEach(routes) { route in
                    HStack {
                        Image(systemName: "network").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(route.name).font(.headline)
                            Text(route.modelID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Group {
                            if let window = route.contextWindow { Text("Context window: \(window)") }
                            else { Text("Context window required") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).tag(route.id)
                }
            }.overlay {
                if routes.isEmpty { ContentUnavailableView("No Model Connected", systemImage: "key", description: Text("Add a connection, then select it in a conversation.")) }
            }
            HStack {
                Button("Add Connection", systemImage: "plus") { editing = nil; showEditor = true }
                Button("Edit") { editing = routes.first { $0.id == selectedID }; showEditor = true }.disabled(selectedID == nil)
                Button("Test Text") { runProbe(.text) }.disabled(selectedID == nil || isWorking)
                Button("Test Tools") { runProbe(.tools) }.disabled(selectedID == nil || isWorking)
                if probeTask != nil { Button("Cancel Test") { probeTask?.cancel() } }
                Spacer()
                Button("Remove", role: .destructive) {
                    guard let route = routes.first(where: { $0.id == selectedID }) else { return }
                    Task { do { try await container.removeRoute(route); selectedID = nil } catch { status = MiraError.safe(error).message } }
                }.disabled(selectedID == nil || container.isDemo)
            }
            Text("This route is used for conversations. Extraction, compaction, and embeddings will be available in later milestones.").font(.caption).foregroundStyle(.secondary)
            Text("Tests send a fixed synthetic prompt without personal history. Your provider may charge a small API fee.").font(.caption).foregroundStyle(.secondary)
            if let route = routes.first(where: { $0.id == selectedID }), let observation = route.probeObservation {
                LabeledContent(LocalizedStringKey(observation.type == .text ? "Latest Text Test" : "Latest Tool Test")) {
                    Text(LocalizedStringKey(observation.state == .verified ? "Passed" : "Failed"))
                    Text(observation.checkedAt, format: .dateTime)
                }.font(.caption).foregroundStyle(observation.state == .verified ? .green : .orange)
                if let error = observation.error { Text(L10n.error(error, locale: locale)).font(.caption).foregroundStyle(.secondary) }
            }
            if !status.isEmpty { Text(L10n.string(status, locale: locale)).font(.callout).foregroundStyle(.secondary) }
        }.padding(.top, 16)
    }
    private func runProbe(_ kind: CapabilityProbeKind) {
        guard let route = routes.first(where: { $0.id == selectedID }) else { return }
        isWorking = true
        status = "Testing with synthetic content only, without conversation history…"
        probeTask = Task {
            let observation = await container.probe(route, kind: kind)
            defer { isWorking = false; probeTask = nil }
            guard !Task.isCancelled else { status = "Test cancelled. Capability status was not changed."; return }
            guard observation.state != .unknown else {
                status = observation.error?.message ?? "Capability test failed."
                return
            }
            do { try await container.saveProbe(observation, for: route); status = observation.state == .verified ? "Test passed. Capability status saved." : (observation.error?.message ?? "Capability test failed. Status recorded.") }
            catch { status = MiraError.safe(error).message }
        }
    }

    private var dataSettings: some View {
        Form {
            Section("Local Library") {
                LabeledContent("Directory") { Text(container.directory.path).textSelection(.enabled).lineLimit(3) }
                if let diagnostics {
                    LabeledContent("SQLite", value: diagnostics.sqliteVersion)
                    LabeledContent("FTS5") { Text(LocalizedStringKey(diagnostics.supportsFTS5 ? "Available" : "Unavailable")) }
                    LabeledContent("Trigram") { Text(LocalizedStringKey(diagnostics.supportsTrigram ? "Available" : "Unavailable")) }
                }
                Text("Use disposable data during development. Memory, source files, and long-term recovery will be verified in later milestones.").font(.caption).foregroundStyle(.secondary)
                if let message = container.maintenanceMessage {
                    Text(L10n.string(message, locale: locale)).font(.callout).foregroundStyle(.orange)
                    Button("Retry Credential Cleanup") { Task { await container.retryCredentialCleanup() } }
                }
            }
            Section("Backup and Restore") {
                Text("Backups contain conversations, configuration, and local request records, but no API keys. Store backups securely. Restoring creates a separate directory and preserves the current library.")
                HStack {
                    Button("Export Library Backup…") { exportBackup() }
                    Button("Restore to New Directory…") { restoreBackup() }
                }.disabled(isWorking)
                if !status.isEmpty { Text(L10n.string(status, locale: locale)).font(.callout).textSelection(.enabled) }
                if let restoredPath { LabeledContent("Restored Library") { Text(verbatim: restoredPath).textSelection(.enabled) } }
            }
        }.formStyle(.grouped)
    }
    private func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Mira-backup.sqlite"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await container.application?.exportBackup(to: url); status = "Backup saved." }
            catch { status = MiraError.safe(error).message }
        }
    }
    private func restoreBackup() {
        let sourcePanel = NSOpenPanel(); sourcePanel.canChooseDirectories = false; sourcePanel.allowsMultipleSelection = false
        sourcePanel.message = L10n.string("Choose a Mira library backup", locale: locale)
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }
        let folderPanel = NSOpenPanel(); folderPanel.canChooseDirectories = true; folderPanel.canChooseFiles = false
        folderPanel.canCreateDirectories = true; folderPanel.message = L10n.string("Choose a parent directory. Mira will create a separate restored library inside it.", locale: locale)
        guard folderPanel.runModal() == .OK, let parent = folderPanel.url else { return }
        let destination = parent.appendingPathComponent("Mira-Restored-\(UUID().uuidString.prefix(8))", isDirectory: true)
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await container.application?.restoreBackup(from: source, to: destination)
                restoredPath = destination.path
                status = "Backup verified and restored. The current library is still open. See the development guide to switch libraries."
            } catch { status = MiraError.safe(error).message }
        }
    }
}

private struct ProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let container: AppContainer
    let existing: ModelRoute?
    @State private var name = ""
    @State private var kind = ProviderKind.openAICompatible
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var modelID = ""
    @State private var apiKey = ""
    @State private var contextWindow = ""
    @State private var maxOutputTokens = "1024"
    @State private var allowsHTTP = false
    @State private var requestsUsage = true
    @State private var confirmsText = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(existing == nil ? "Add Model Connection" : "Edit Model Connection")).font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                Picker("Protocol", selection: Binding(get: { kind }, set: { newKind in
                    guard kind != newKind else { return }
                    kind = newKind
                    baseURL = newKind == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
                })) {
                    Text("OpenAI Chat Completions Compatible").tag(ProviderKind.openAICompatible)
                    Text("Anthropic Messages").tag(ProviderKind.anthropic)
                }
                TextField("Base URL", text: $baseURL)
                TextField("Model ID", text: $modelID)
                SecureField(LocalizedStringKey(existing == nil ? "API Key" : "New API Key (leave blank to keep)"), text: $apiKey)
                TextField("Context Window (tokens)", text: $contextWindow)
                TextField("Maximum Output (tokens)", text: $maxOutputTokens)
                Toggle("I confirm this model supports streaming text conversations", isOn: $confirmsText)
                if kind == .openAICompatible { Toggle("Request streaming token usage (requires include_usage support)", isOn: $requestsUsage) }
                Toggle("Allow explicitly configured local HTTP services", isOn: $allowsHTTP)
            }
            Text("Enter the model ID manually. You can save without a context window, but must provide one before sending. Tool capability is not inferred automatically. Saving a connection does not incur model fees.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.string(error, locale: locale)).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { apiKey = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || name.isEmpty || modelID.isEmpty || container.isDemo)
            }
        }.padding(28).frame(width: 590)
            .onAppear { load() }
    }
    private func load() {
        guard let existing else { return }
        name = existing.name; kind = existing.providerKind; baseURL = existing.baseURL
        modelID = existing.modelID; contextWindow = existing.contextWindow.map(String.init) ?? ""
        maxOutputTokens = String(existing.maxOutputTokens); allowsHTTP = existing.allowsLoopbackHTTP
        requestsUsage = existing.requestsUsage; confirmsText = existing.textCapability == .declared || existing.textCapability == .verified
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            let windowText = contextWindow.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let output = Int(maxOutputTokens), output > 0,
                  windowText.isEmpty || (Int(windowText).map { $0 > output && $0 <= 10_000_000 } ?? false) else { throw MiraError(.configuration, "Enter valid token limits. Maximum output must be smaller than the context window.") }
            var route = ModelRoute(id: existing?.id ?? .init(), revision: (existing?.revision ?? 0) + 1,
                                   name: name.trimmingCharacters(in: .whitespacesAndNewlines), providerKind: kind,
                                   baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                                   credentialReference: existing?.credentialReference ?? UUID().uuidString,
                                   credentialVersion: existing?.credentialVersion ?? 1, contextWindow: Int(windowText), maxOutputTokens: output,
                                   textCapability: confirmsText ? .declared : .unknown, allowsLoopbackHTTP: allowsHTTP, requestsUsage: requestsUsage)
            if let existing, existing.providerKind == route.providerKind, existing.baseURL == route.baseURL,
               existing.modelID == route.modelID, existing.contextWindow == route.contextWindow,
               existing.maxOutputTokens == route.maxOutputTokens, existing.allowsLoopbackHTTP == route.allowsLoopbackHTTP,
               existing.requestsUsage == route.requestsUsage, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                route.toolCapability = existing.toolCapability
                // Changing an explicit declaration invalidates an observation only for that dimension.
                if confirmsText == (existing.textCapability == .verified || existing.textCapability == .declared) {
                    route.textCapability = existing.textCapability; route.probeObservation = existing.probeObservation
                }
            }
            _ = try route.validatedEndpoint()
            try await container.saveRoute(route, previous: existing, secret: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            apiKey = ""; dismiss()
        } catch { self.error = MiraError.safe(error).message }
    }
}
