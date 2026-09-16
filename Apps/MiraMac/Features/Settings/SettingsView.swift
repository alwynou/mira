import MiraCore
import Observation
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, providers, models, memory, data
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .models: "Models"
        case .memory: "Memory"
        case .data: "Data & Privacy"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"  // i18n-verbatim: SF Symbol identifier.
        case .providers: "cloud"  // i18n-verbatim: SF Symbol identifier.
        case .models: "sparkles"  // i18n-verbatim: SF Symbol identifier.
        case .memory: "brain"  // i18n-verbatim: SF Symbol identifier.
        case .data: "checkmark.shield"  // i18n-verbatim: SF Symbol identifier.
        }
    }
}

enum SettingsDestination: Hashable {
    case category(SettingsCategory)
    // Provider destinations select the detail pane inside the shared Providers page.
    case provider(ConnectionID)
    case catalogProvider(String)

    var category: SettingsCategory {
        switch self {
        case .category(let value): value
        case .provider, .catalogProvider: .providers
        }
    }
}

/// Owns the standalone settings window state, independently of its active page.
@MainActor @Observable
final class SettingsModel {
    private(set) var providers: ProviderLibraryModel
    private(set) var routing: ProviderLibraryModel
    private(set) var memory: MemorySettingsModel
    private(set) var data: DataSettingsModel
    private(set) var sessionID = UUID()
    private(set) var visited: Set<SettingsCategory> = [.general]
    var destination = SettingsDestination.category(.general)
    private var destinations: [SettingsCategory: SettingsDestination] = [:]
    @ObservationIgnored private let container: AppContainer
    @ObservationIgnored private var retiredProviders: Task<Void, Never>?
    @ObservationIgnored private var retiredMemory: Task<Void, Never>?
    @ObservationIgnored private var retiredData: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
        providers = ProviderLibraryModel(container: container)
        routing = ProviderLibraryModel(container: container)
        memory = MemorySettingsModel(container: container)
        data = DataSettingsModel(container: container)
    }

    func destination(for category: SettingsCategory) -> SettingsDestination {
        destinations[category] ?? .category(category)
    }

    func navigate(_ next: SettingsDestination) {
        let resolved: SettingsDestination
        if case .category(let category) = next { resolved = destination(for: category) } else { resolved = next }
        guard resolved != destination else { return }
        #if DEBUG
            ProviderSettingsTiming.begin(resolved, entering: destination.category != .providers)
        #endif
        destinations[resolved.category] = resolved
        visited.insert(resolved.category)
        destination = resolved
    }

    func navigate(_ next: SettingsDestination, from category: SettingsCategory) {
        if destination.category == category { navigate(next) } else { destinations[next.category] = next }
    }

    /// A window session owns transient navigation, drafts and scroll positions.
    func close() {
        let previousProviders = retiredProviders
        let oldProviders = providers
        let oldRouting = routing
        retiredProviders = Task {
            await previousProviders?.value
            await oldProviders.stopRequests()
            await oldRouting.stopRequests()
        }
        let previous = retiredMemory
        let oldMemory = memory
        retiredMemory = Task {
            await previous?.value
            await oldMemory.stop()
        }
        providers = ProviderLibraryModel(container: container)
        routing = ProviderLibraryModel(container: container)
        memory = MemorySettingsModel(container: container)
        let previousData = retiredData
        let oldData = data
        oldData.clearResults()
        retiredData = Task {
            await previousData?.value
            await oldData.stopObserving()
        }
        if !data.isWorking { data = DataSettingsModel(container: container) }
        destination = .category(.general)
        destinations = [:]
        visited = [.general]
        sessionID = UUID()
    }

}

#if DEBUG
    /// Opt-in offline diagnostic: action delivery to the selected editor's first layout.
    /// It records durations only, never provider configuration or credentials.
    @MainActor
    enum ProviderSettingsTiming {
        private static var pending: (destination: SettingsDestination, start: ContinuousClock.Instant, phase: String)?

        static func begin(_ destination: SettingsDestination, entering: Bool) {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--demo"), arguments.contains("--profile-provider-settings"),
                destination.category == .providers
            else {
                pending = nil
                return
            }
            pending = (destination, .now, entering ? "entry" : "switch")
        }

        static func didLayout(_ destination: SettingsDestination?) {
            guard let pending, pending.destination == destination || pending.destination == .category(.providers) else {
                return
            }
            let elapsed = pending.start.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            print("Provider settings \(pending.phase) layout milliseconds: \(milliseconds)")
            self.pending = nil
        }
    }
#endif

struct SettingsSidebar: View {
    let model: SettingsModel

    var body: some View {
        List(
            selection: Binding<SettingsCategory?>(
                get: { model.destination.category },
                set: { if let category = $0 { model.navigate(.category(category)) } }
            )
        ) {
            ForEach(SettingsCategory.allCases) { category in
                Label {
                    Text(category.title)
                } icon: {
                    Image(systemName: category.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: MiraTheme.Settings.sidebarIconSize, height: MiraTheme.Settings.sidebarIconSize)
                        .background(category.iconColor, in: .rect(cornerRadius: MiraTheme.Settings.iconRadius))
                }
                .tag(category)
                .accessibilityIdentifier("settings.category.\(category.rawValue)")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .font(MiraTheme.Settings.body)
        .tint(MiraTheme.Settings.accent)
        .environment(\.defaultMinListRowHeight, MiraTheme.Settings.sidebarRowHeight)
        .accessibilityIdentifier("settings.sidebar")
    }
}

extension SettingsCategory {
    fileprivate var iconColor: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .providers, .models: Color(nsColor: .systemBlue)
        case .memory: Color(nsColor: .systemPurple)
        case .data: Color(nsColor: .systemGreen)
        }
    }
}

/// Retains visited pages for this window session, then resets when the window closes.
struct MiraSettingsRoot: View {
    let model: SettingsModel

    var body: some View {
        MiraSettingsNavigation {
            SettingsSidebar(model: model)
        } detail: {
            SettingsView(model: model)
        }
        .id(model.sessionID)
        .navigationTitle(model.destination.category.title)
        .onDisappear { model.close() }
        .frame(minWidth: MiraTheme.Settings.minWidth, minHeight: MiraTheme.Settings.minHeight)
        .accessibilityIdentifier("settings.root")
    }
}

struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        page.modifier(MiraSettingsTitlebar(title: model.destination.category.title))
    }

    private var page: some View {
        ZStack {
            ForEach(SettingsCategory.allCases.filter { model.visited.contains($0) }) { category in
                retainedPage(category)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(model.destination.category == category ? 1 : 0)
                    .allowsHitTesting(model.destination.category == category)
                    .disabled(model.destination.category != category)
                    .accessibilityHidden(model.destination.category != category)
                    .environment(\.miraSettingsPageActive, model.destination.category == category)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(MiraTheme.Settings.body)
        .foregroundStyle(MiraTheme.Settings.text)
    }

    @ViewBuilder private func retainedPage(_ category: SettingsCategory) -> some View {
        switch category {
        case .general:
            GeneralSettingsView()
        case .memory:
            MemorySettingsView(model: model.memory)
        case .data:
            DataSettingsView(model: model.data)
        case .providers, .models:
            let library = category == .providers ? model.providers : model.routing
            ProviderConfigurationView(
                model: library, destination: model.destination(for: category),
                navigate: { model.navigate($0, from: category) }
            )
            .task(id: model.destination.category == category) {
                guard model.destination.category == category else { return }
                await library.observe(includeRoutingScopes: category == .models)
            }
        }
    }
}
