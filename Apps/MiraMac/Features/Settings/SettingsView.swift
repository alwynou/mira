import SwiftUI
import MiraCore
import Observation

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
        case .general: "gearshape" // i18n-verbatim: SF Symbol identifier.
        case .providers: "cloud" // i18n-verbatim: SF Symbol identifier.
        case .models: "sparkles" // i18n-verbatim: SF Symbol identifier.
        case .memory: "brain" // i18n-verbatim: SF Symbol identifier.
        case .data: "checkmark.shield" // i18n-verbatim: SF Symbol identifier.
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
    let providers: ProviderLibraryModel
    let memory: MemorySettingsModel
    let data: DataSettingsModel
    var destination = SettingsDestination.category(.general)

    init(container: AppContainer) {
        providers = ProviderLibraryModel(container: container)
        memory = MemorySettingsModel(container: container)
        data = DataSettingsModel(container: container)
    }

    func navigate(_ next: SettingsDestination) {
        guard next != destination else { return }
        providers.stopRequests()
        destination = next
    }
}

struct SettingsSidebar: View {
    let model: SettingsModel

    var body: some View {
        List(selection: Binding<SettingsCategory?>(
            get: { model.destination.category },
            set: { if let category = $0 { model.navigate(.category(category)) } }
        )) {
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

private extension SettingsCategory {
    var iconColor: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .providers, .models: Color(nsColor: .systemBlue)
        case .memory: Color(nsColor: .systemPurple)
        case .data: Color(nsColor: .systemGreen)
        }
    }
}

/// The SwiftUI window scene owns presentation; the app retains preference drafts.
struct MiraSettingsRoot: View {
    let model: SettingsModel

    var body: some View {
        MiraSettingsNavigation {
            SettingsSidebar(model: model)
        } detail: {
            SettingsView(model: model)
        }
        .navigationTitle(model.destination.category.title)
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
        Group {
            switch model.destination.category {
            case .general:
                GeneralSettingsView()
            case .memory:
                MemorySettingsView(model: model.memory, onManageModels: { model.navigate(.category(.models)) })
            case .data:
                DataSettingsView(model: model.data)
            case .providers, .models:
                ProviderConfigurationView(model: model.providers, destination: model.destination, navigate: model.navigate)
                    .task { await model.providers.observe() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(MiraTheme.Settings.body)
        .foregroundStyle(MiraTheme.Settings.text)
        .onDisappear { model.providers.stopRequests() }
    }
}
