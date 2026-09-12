import SwiftUI

/// A self-contained component gallery. Preview data never opens a library or provider.
private struct MiraComponentPreview: View {
    @State private var selectedRow = "Inbox"

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                Text("Mira").font(MiraTheme.Typography.title)
                VStack(spacing: 2) {
                    Button { selectedRow = "Inbox" } label: {
                        MiraSidebarRow(isSelected: selectedRow == "Inbox") {
                            Label("Inbox", systemImage: "tray")
                        }
                    }
                    Button { selectedRow = "Memories" } label: {
                        MiraSidebarRow(isSelected: selectedRow == "Memories") {
                            Label("Memories", systemImage: "brain")
                        }
                    }
                    Button { selectedRow = "Knowledge" } label: {
                        MiraSidebarRow(isSelected: selectedRow == "Knowledge") {
                            Label("Knowledge", systemImage: "book.closed")
                        }
                    }
                }
                .buttonStyle(MiraRowButtonStyle())
            }
            .padding(MiraTheme.Spacing.lg)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .navigationSplitViewColumnWidth(min: MiraTheme.Layout.sidebarMin, ideal: MiraTheme.Layout.sidebarIdeal, max: MiraTheme.Layout.sidebarMax)
        } detail: {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                MiraBrandMark().frame(width: 56, height: 40)
                Text("Start with an idea").font(MiraTheme.Typography.welcome)
                HStack(spacing: MiraTheme.Spacing.md) {
                    Button("New conversation", systemImage: "square.and.pencil") {}
                        .buttonStyle(MiraPrimaryButtonStyle())
                    Button("Settings", systemImage: "gearshape") {}
                        .labelStyle(.iconOnly).buttonStyle(MiraIconButtonStyle())
                    Button("Send", systemImage: "arrow.up") {}
                        .labelStyle(.iconOnly).buttonStyle(MiraCircleButtonStyle())
                    Button("Send", systemImage: "arrow.up") {}
                        .labelStyle(.iconOnly).buttonStyle(MiraCircleButtonStyle()).disabled(true)
                    Button("Jump to latest", systemImage: "arrow.down") {}
                        .labelStyle(.iconOnly).buttonStyle(MiraGlassCircleButtonStyle())
                }
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                        Text("Send a message…").foregroundStyle(MiraTheme.Colors.secondaryText)
                        MiraComposerBarLayout {
                            Color.clear.frame(width: 0, height: 0)
                            Text("Local demo").font(MiraTheme.Typography.composerFootnote)
                                .foregroundStyle(MiraTheme.Colors.secondaryText)
                            HStack(spacing: MiraTheme.Spacing.sm) {
                                Text("Use default model").font(MiraTheme.Typography.composerModel)
                                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                                Button("Stop", systemImage: "stop.fill") {}
                                    .labelStyle(.iconOnly).buttonStyle(MiraCircleButtonStyle())
                            }
                        }
                    }
                    .padding(MiraTheme.Spacing.lg)
                    .frame(width: 360)
                }
                .modifier(MiraComposerGlass())
            }
            .padding(MiraTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MiraTheme.Colors.canvas)
        }
        .frame(width: 800, height: 460)
        .foregroundStyle(MiraTheme.Colors.text)
        .containerBackground(MiraTheme.Colors.canvas, for: .window)
    }
}

#Preview("Components · Light") {
    MiraComponentPreview().environment(\.locale, Locale(identifier: "en")).preferredColorScheme(.light)
}

#Preview("Components · Dark") {
    MiraComponentPreview().environment(\.locale, Locale(identifier: "en")).preferredColorScheme(.dark)
}

private struct MiraTitlebarMaterialPreview: View {
    var body: some View {
        MiraScrollEdgeViewport(title: "Mira", topInset: 52) {
            if #available(macOS 26.0, *) {
                sampleScrollView.scrollEdgeEffectHidden()
            } else {
                sampleScrollView
            }
        }
        .background(MiraTheme.Colors.canvas)
        .frame(width: 600, height: 420)
    }

    private var sampleScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                ForEach(0..<12) { _ in
                    Label("Start with an idea", systemImage: "sparkles")
                        .font(MiraTheme.Typography.title)
                    Text("Organize your thoughts, discuss a project, or ask a question.\nChoose a model, then write your first message.")
                }
            }
            .padding(MiraTheme.Spacing.xl)
            .padding(.top, 52)
        }
    }
}

#Preview("Titlebar material · Light") {
    MiraTitlebarMaterialPreview().environment(\.locale, Locale(identifier: "en")).preferredColorScheme(.light)
}

#Preview("Titlebar material · Dark") {
    MiraTitlebarMaterialPreview().environment(\.locale, Locale(identifier: "zh-CN")).preferredColorScheme(.dark)
}

/// Native settings examples stay isolated from UserDefaults, libraries and provider traffic.
private struct MiraNativeSettingsPreview: View {
    @State private var language = "en"
    @State private var mode = "system"
    @State private var enabled = true
    @State private var budget = "12000"
    @State private var model = ""

    var body: some View {
        MiraSettingsPage {
            MiraSettingsSection("Language") {
                MiraSettingsRow("Display Language", subtitle: "Changes apply immediately to all Mira windows and are saved for the next launch. Conversation content and model response language are not changed. macOS manages the language of system menus and file dialogs.") {
                    MiraSettingsSelect(title: "Display Language", selection: $language,
                        options: [.init(id: "en", title: "English"), .init(id: "zh-CN", title: "Chinese (Simplified)")],
                        identifier: "preview.language", maximumWidth: 180)
                }
            }
            MiraSettingsSection("Appearance") {
                MiraSettingsRow("Display Mode", subtitle: "Choose an appearance for all Mira windows, or follow your system setting.") {
                    MiraSettingsSelect(title: "Display Mode", selection: $mode,
                        options: [.init(id: "system", title: "Follow System"), .init(id: "light", title: "Light"), .init(id: "dark", title: "Dark")],
                        identifier: "preview.mode", maximumWidth: 180)
                }
            }
            MiraSettingsSection("Automatic memory") {
                Toggle("Active", isOn: $enabled).toggleStyle(.switch)
                MiraSettingsFormRow("Daily token limit", subtitle: "Daily token budget for automatic memory. Resets at 00:00 UTC.") {
                    TextField("Daily token limit", text: $budget)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                }
                MiraSettingsRow("Conversation model") {
                    MiraSettingsSelect(title: "Model", selection: $model,
                        options: [.init(id: "example", title: "Example Model")],
                        identifier: "preview.model", clearSelectionTitle: "Clear Selection", maximumWidth: 180)
                }
                MiraSettingsRow("Memory extraction model") {
                    MiraSettingsSelect(title: "Model", selection: .constant(""), options: [], identifier: "preview.empty", maximumWidth: 180)
                }
                HStack {
                    Button("Discard Changes") {}.buttonStyle(MiraSettingsButtonStyle())
                    Spacer()
                    Button("Save") {}.buttonStyle(MiraSettingsButtonStyle(isPrimary: true)).disabled(true)
                }
            }
            MiraSettingsSection("Provider Models", actions: {
                Button("Fetch Models", systemImage: "arrow.clockwise") {}
                    .labelStyle(.iconOnly)
                Button("Add Manually", systemImage: "plus") {}
                    .labelStyle(.iconOnly)
            }) {
                MiraProviderModelRow(name: "Example Model", modelID: "example/model-with-a-long-identifier",
                    providerID: "openai", supportsVision: true, supportsTools: true,
                    supportsThinking: true, contextWindow: 128_000, isEnabled: $enabled)
                MiraProviderModelRow(name: "Example Model with a longer display name", modelID: "example/long-model-family-version",
                    pricing: .init(input: "$0.50", output: "$1.20"),
                    supportsTools: true, contextWindow: 1_000_000, isEnabled: $enabled)
            }
        }
    }
}

#Preview("Native settings · Light · English") {
    MiraNativeSettingsPreview()
        .environment(\.locale, Locale(identifier: "en")).preferredColorScheme(.light)
        .frame(width: MiraTheme.Settings.minWidth - MiraTheme.Settings.sidebarWidth, height: MiraTheme.Settings.minHeight)
}

#Preview("Native settings · Dark · Chinese") {
    MiraNativeSettingsPreview()
        .environment(\.locale, Locale(identifier: "zh-Hans")).preferredColorScheme(.dark)
        .frame(width: MiraTheme.Settings.minWidth - MiraTheme.Settings.sidebarWidth, height: MiraTheme.Settings.minHeight)
}

private struct MiraProviderSelectionRailPreview: View {
    private struct Provider: Identifiable {
        let id: String
        let name: String
    }

    @State private var selectedProviderID = "openai"

    private let providers = [
        Provider(id: "openai", name: "OpenAI"),
        Provider(id: "anthropic", name: "Anthropic"),
        Provider(id: "kimi-for-coding", name: "Kimi Code"),
        Provider(id: "moonshotai", name: "Moonshot"),
        Provider(id: "deepseek", name: "DeepSeek"),
        Provider(id: "openrouter", name: "OpenRouter")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            Text("Providers")
                .font(MiraTheme.Settings.section)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(providers) { provider in
                        MiraProviderSelectionCard(
                            name: provider.name,
                            providerID: provider.id,
                            isSelected: selectedProviderID == provider.id) {
                                selectedProviderID = provider.id
                            }
                    }
                }
                .padding(.vertical, MiraTheme.Spacing.xs)
            }
            Text(verbatim: selectedProviderID)
                .font(MiraTheme.Settings.caption)
                .foregroundStyle(MiraTheme.Settings.secondaryText)
        }
        .padding(MiraTheme.Spacing.lg)
        .frame(width: 520, alignment: .leading)
        .foregroundStyle(MiraTheme.Settings.text)
        .background(MiraTheme.Settings.canvas)
    }
}

#Preview("Provider selector rail · Light") {
    MiraProviderSelectionRailPreview()
        .preferredColorScheme(.light)
}

#Preview("Provider selector rail · Dark") {
    MiraProviderSelectionRailPreview()
        .preferredColorScheme(.dark)
}

#Preview("Lazy provider models · 1000 rows") {
    MiraSettingsLazyPage {
        MiraSettingsSection {
            MiraSettingsFormRow("Test Model") {
                MiraSettingsSelect(title: "Test Model", selection: .constant("example/model-0"),
                                   options: (0..<1_000).map { .init(id: "example/model-\($0)", verbatimTitle: "Example Model \($0)") },
                                   identifier: "preview.large-model-menu", maximumWidth: 220)
            }
        }
        MiraSettingsSection("Provider Models", isCollection: true) {
            ForEach(0..<1_000, id: \.self) { index in
                MiraSettingsLazyRow(isFirst: index == 0, isLast: index == 999) {
                    MiraProviderModelRow(name: "Example Model \(index)", modelID: "example/model-\(index)",
                                         providerID: "openai", supportsTools: true, contextWindow: 128_000,
                                         isEnabled: .constant(false))
                }
            }
        }
    }
    .frame(width: MiraTheme.Settings.minWidth - MiraTheme.Settings.sidebarWidth,
           height: MiraTheme.Settings.minHeight)
    .environment(\.locale, Locale(identifier: "en"))
}

private struct MiraCredentialFieldsPreview: View {
    @State private var unsavedText = ""
    @State private var savedText = "synthetic-stored-key"

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
            MiraSettingsFormRow("API Key") {
                MiraSettingsCredentialField(text: $unsavedText, hasStoredKey: false)
            }
            MiraSettingsFormRow("API Key") {
                MiraSettingsCredentialField(text: $savedText, hasStoredKey: true)
            }
        }
        .padding(MiraTheme.Spacing.lg)
        .frame(width: 520, alignment: .leading)
        .foregroundStyle(MiraTheme.Settings.text)
        .background(MiraTheme.Settings.canvas)
    }
}

#Preview("Credential fields · Saved and unsaved") {
    MiraCredentialFieldsPreview()
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(.light)
}

private struct MiraSettingsNavigationPreview: View {
    @State private var selected = SettingsCategory.general

    var body: some View {
        MiraSettingsNavigation {
            List(selection: $selected) {
                ForEach(SettingsCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbol).tag(category)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } detail: {
            MiraNativeSettingsPreview()
                .modifier(MiraSettingsTitlebar(title: selected.title))
        }
        .navigationTitle(selected.title)
        .containerBackground(MiraTheme.Settings.canvas, for: .window)
    }
}

#Preview("SwiftUI settings · Fixed sidebar · Light") {
    MiraSettingsNavigationPreview()
        .environment(\.locale, Locale(identifier: "en")).preferredColorScheme(.light)
        .frame(width: MiraTheme.Settings.windowWidth, height: MiraTheme.Settings.windowHeight)
}

#Preview("SwiftUI settings · Fixed sidebar · Dark · Minimum") {
    MiraSettingsNavigationPreview()
        .environment(\.locale, Locale(identifier: "zh-Hans")).preferredColorScheme(.dark)
        .frame(width: MiraTheme.Settings.minWidth, height: MiraTheme.Settings.minHeight)
}

#Preview("Native settings · Field alignment and actions") {
    HStack(spacing: 0) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            MiraSettingsPage {
                MiraSettingsSection("Provider") {
                    MiraSettingsFormRow("API Key") {
                        SecureField("API Key", text: .constant(""))
                            .textFieldStyle(.roundedBorder)
                    }
                    MiraSettingsFormRow("API Proxy URL") {
                        TextField("API Proxy URL", text: .constant("https://example.invalid/v1"))
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Spacer()
                        Button("Discard Changes") {}.buttonStyle(MiraSettingsButtonStyle())
                        Button("Save") {}.buttonStyle(MiraSettingsButtonStyle(isPrimary: true))
                    }
                }
            }
            .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(scheme)
            .frame(width: 360, height: 240)
        }
    }
}

#Preview("Native settings · Scrolling titlebar") {
    HStack(spacing: 0) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            MiraSettingsPage {
                ForEach(0..<12) { index in
                    MiraSettingsSection("Provider") {
                        LabeledContent("Model") {
                            Text(verbatim: "example-model-\(index)")
                        }
                    }
                }
            }
            .modifier(MiraSettingsTitlebar(title: "Providers"))
            // Supply the inset normally provided by the AppKit window toolbar.
            .safeAreaPadding(.top, 52)
            .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(scheme)
            .frame(width: 400, height: 400)
        }
    }
}
