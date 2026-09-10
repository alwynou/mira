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

/// Owns settings state for the lifetime of its main window, independently of pages.
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
    @Environment(WindowNavigation.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { navigation.returnToConversation() } label: {
                MiraSidebarRow {
                    Label("Back to Mira", systemImage: "arrow.left")
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                }
            }
            .buttonStyle(MiraRowButtonStyle())
            .padding(.horizontal, MiraTheme.Spacing.sm)
            .padding(.bottom, MiraTheme.Spacing.lg)
            .accessibilityIdentifier("settings.return")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsCategory.allCases) { category in
                        Button { model.navigate(.category(category)) } label: {
                            MiraSidebarRow(isSelected: model.destination.category == category) {
                                Label(category.title, systemImage: category.symbol)
                            }
                        }
                        .buttonStyle(MiraRowButtonStyle())
                        .accessibilityIdentifier("settings.category.\(category.rawValue)")
                    }
                }
                .padding(.horizontal, MiraTheme.Spacing.sm)
                .padding(.bottom, MiraTheme.Spacing.lg)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
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
        .background(MiraTheme.Colors.canvas)
        .font(MiraTheme.Typography.body)
        .foregroundStyle(MiraTheme.Colors.text)
        .onDisappear { model.providers.stopRequests() }
    }
}
