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

#Preview("Provider model rows · Wrapped content height") {
    @Previewable @State var enabled = true
    // The wrapped rows set the panel's natural height below its 480 pt cap.
    MiraProviderModelList(rowCount: 3) {
        MiraProviderModelRow(
            name: "GPT-4.1",
            modelID: "openai/gpt-4.1-2025-04-14",
            pricing: .init(input: "$2.00", output: "$8.00"),
            providerID: "openai",
            supportsVision: true,
            supportsTools: true,
            contextWindow: 1_000_000,
            isEnabled: $enabled
        )
        MiraSettingsDivider()
        MiraProviderModelRow(
            name: "A long model display name that wraps cleanly",
            modelID: "anthropic/claude-3-7-sonnet-latest-with-a-long-identifier",
            providerID: "anthropic",
            supportsTools: true,
            supportsThinking: true,
            isEnabled: $enabled
        )
        MiraSettingsDivider()
        MiraProviderModelRow(
            name: "Kimi K3",
            modelID: "k3",
            providerID: "kimi-for-coding",
            supportsVision: true,
            supportsTools: true,
            supportsThinking: true,
            contextWindow: 1_000_000,
            isEnabled: $enabled
        )
    }
    .padding(MiraTheme.Spacing.lg)
    .frame(width: 360)
    .background(MiraTheme.Colors.canvas)
    .foregroundStyle(MiraTheme.Colors.text)
    .environment(\.locale, Locale(identifier: "en"))
    .preferredColorScheme(.light)
}

/// Compact provider navigation and detail are previewed without an application container.
private struct MiraProviderSettingsPreview: View {
    private struct Provider: Identifiable {
        let id: String
        let name: String
    }
    private let providers = [
        Provider(id: "openai", name: "OpenAI"),
        Provider(id: "anthropic", name: "Anthropic"),
        Provider(id: "kimi-for-coding", name: "Kimi Code"),
        Provider(id: "moonshotai-cn", name: "Moonshot"),
        Provider(id: "deepseek", name: "DeepSeek"),
        Provider(id: "openrouter", name: "OpenRouter")
    ]
    @State private var selectedID = "openai"
    @State private var key = ""
    @State private var baseURL = "https://api.example.com/v1"
    @State private var testModel = "example-model"
    @State private var enabled = false

    var body: some View {
        MiraSettingsSplitPage(title: "Providers", subtitle: "Manage provider connections and models.") {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
                MiraProviderGroup("Active Providers") {
                    ForEach(providers.prefix(1)) { provider in
                        Button { selectedID = provider.id } label: {
                            MiraProviderRow(name: provider.name, providerID: provider.id, state: "Active",
                                            isSelected: provider.id == selectedID, isActive: true)
                        }
                    }
                }
                MiraProviderGroup("Inactive Providers") {
                    ForEach(providers.dropFirst()) { provider in
                        Button { selectedID = provider.id } label: {
                            MiraProviderRow(name: provider.name, providerID: provider.id, state: "Not configured",
                                            isSelected: provider.id == selectedID)
                        }
                    }
                }
            }
            .buttonStyle(MiraRowButtonStyle())
        } detail: {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                HStack(spacing: MiraTheme.Spacing.md) {
                    MiraProviderIcon(providerID: selectedID, size: MiraTheme.Layout.providerHeadingIconSize)
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                        Text(verbatim: providers.first { $0.id == selectedID }?.name ?? "")
                            .font(MiraTheme.Typography.providerTitle)
                        Text(verbatim: "https://api.example.com/v1")
                            .font(MiraTheme.Typography.caption)
                            .foregroundStyle(MiraTheme.Colors.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Toggle("Active", isOn: $enabled).toggleStyle(.switch)
                        .controlSize(.small).font(MiraTheme.Typography.caption)
                }
                MiraSettingsSection {
                    MiraSettingsFormRow("API Key") {
                        SecureField("API Key", text: $key).textFieldStyle(MiraSettingsTextFieldStyle())
                    }
                    MiraSettingsDivider()
                    MiraSettingsFormRow("API Proxy URL") {
                        TextField("API Proxy URL", text: $baseURL).textFieldStyle(MiraSettingsTextFieldStyle())
                    }
                    MiraSettingsDivider()
                    MiraSettingsFormRow("Test Connectivity", subtitle: "Testing sends a short request using the selected model. Enabling requires a successful test. A saved API key can be reused.") {
                        HStack(spacing: MiraTheme.Spacing.sm) {
                            MiraSettingsSelect(title: "Test Model", selection: $testModel,
                                               options: [.init(id: "example-model", title: "Model")],
                                               identifier: "preview.provider.testModel", minimumWidth: 80, maximumWidth: 180)
                            Button("Test") {}.buttonStyle(MiraSettingsButtonStyle()).fixedSize().disabled(key.isEmpty)
                        }
                    }
                }
                HStack {
                    Spacer()
                    if !key.isEmpty {
                        Button("Discard Changes") { key = "" }.buttonStyle(MiraSettingsButtonStyle())
                    }
                    Button("Save") {}.buttonStyle(MiraSettingsButtonStyle(isPrimary: true)).disabled(true)
                }
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                    Text("Provider Models").font(MiraTheme.Typography.body.weight(.semibold))
                    MiraProviderModelList(rowCount: 2) {
                        MiraProviderModelRow(name: "GPT-4.1", modelID: "gpt-4.1",
                                             pricing: .init(input: "$2.00", output: "$8.00"), providerID: "openai",
                                             supportsVision: true, supportsTools: true, contextWindow: 1_000_000, isEnabled: $enabled)
                        MiraSettingsDivider()
                        MiraProviderModelRow(name: "Kimi K3", modelID: "k3", providerID: "kimi-for-coding",
                                             supportsVision: true, supportsTools: true, supportsThinking: true,
                                             contextWindow: 1_000_000, isEnabled: $enabled)
                    }
                }
            }
        }
        .font(MiraTheme.Typography.body)
        .foregroundStyle(MiraTheme.Colors.text)
    }
}

#Preview("Providers · Light") {
    MiraProviderSettingsPreview()
        .frame(width: 1100 - MiraTheme.Layout.settingsSidebarWidth, height: 760)
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(.light)
}

#Preview("Providers · Dark · Minimum") {
    MiraProviderSettingsPreview()
        .frame(width: 850 - MiraTheme.Layout.settingsSidebarWidth, height: 620)
        .environment(\.locale, Locale(identifier: "zh-CN"))
        .preferredColorScheme(.dark)
}

#Preview("Settings · Dark") {
    @Previewable @State var language = "zh-CN"
    @Previewable @State var displayMode = "dark"
    MiraSettingsPage {
        MiraSettingsHeader(title: "General", subtitle: "Customize Mira's display language and appearance.")
        MiraSettingsSection("Language") {
            MiraSettingsRow("Display Language", subtitle: "Changes apply immediately to all Mira windows and are saved for the next launch. Conversation content and model response language are not changed. macOS manages the language of system menus and file dialogs.") {
                MiraSettingsSelect(title: "Display Language", selection: $language, options: [
                    .init(id: "en", title: "English"),
                    .init(id: "zh-CN", title: "Chinese (Simplified)")
                ], identifier: "preview.language")
            }
        }
        MiraSettingsSection("Appearance") {
            MiraSettingsRow("Display Mode", subtitle: "Choose an appearance for all Mira windows, or follow your system setting.") {
                MiraSettingsSelect(title: "Display Mode", selection: $displayMode, options: [
                    .init(id: "dark", title: "Dark"), .init(id: "light", title: "Light"),
                    .init(id: "system", title: "Follow System")
                ], identifier: "preview.displayMode")
            }
        }
    }
    .frame(width: 850 - MiraTheme.Layout.sidebarIdeal, height: 620)
    .environment(\.locale, Locale(identifier: "zh-CN"))
    .preferredColorScheme(AppDisplayMode.resolve(stored: displayMode).colorScheme)
}

#Preview("Model defaults · Light") {
    @Previewable @State var selected = "example"
    MiraSettingsPage {
        MiraSettingsHeader(title: "Models", subtitle: "Choose models for conversations and memory.")
        MiraSettingsSection {
            MiraSettingsRow("Conversation model", subtitle: "Used for new conversations.") {
                MiraSettingsSelect(title: "Model", selection: $selected,
                                   options: [.init(id: "example", title: "Example Model")],
                                   identifier: "preview.models.conversation", maximumWidth: 240)
            }
        }
        MiraSettingsSection {
            MiraSettingsRow("Memory extraction model", subtitle: "Used to organize memories in the background.") {
                MiraSettingsSelect(title: "Model", selection: $selected,
                                   options: [.init(id: "example", title: "Example Model")],
                                   identifier: "preview.models.memory", maximumWidth: 240)
            }
        }
    }
    .frame(width: 850 - MiraTheme.Layout.settingsSidebarWidth, height: 620)
    .preferredColorScheme(.light)
}

#Preview("Memory settings · Dark") {
    @Previewable @State var mode = "manual"
    @Previewable @State var limit = "10000"
    MiraSettingsPage {
        MiraSettingsHeader(title: "Memory", subtitle: "Configure automatic memory and daily extraction limits.")
        MiraSettingsSection("Automatic memory") {
            MiraSettingsRow("Capture mode", subtitle: "Only memories you save or approve are stored.") {
                MiraSettingsSelect(title: "Capture mode", selection: $mode,
                                   options: [.init(id: "manual", title: "Manual only")],
                                   identifier: "preview.memory.mode", maximumWidth: MiraTheme.Layout.selectMaxWidth)
            }
        }
        MiraSettingsSection("Daily extraction budget") {
            MiraSettingsRow("Daily token limit", subtitle: "Daily token budget for automatic memory. Resets at 00:00 UTC.") {
                TextField("Daily token limit", text: $limit)
                    .textFieldStyle(MiraSettingsTextFieldStyle()).frame(width: 150)
            }
        }
    }
    .frame(width: 850 - MiraTheme.Layout.settingsSidebarWidth, height: 620)
    .environment(\.locale, Locale(identifier: "zh-CN"))
    .preferredColorScheme(.dark)
}

#Preview("Native window · Narrow") {
    @Previewable @State var showsInspector = false
    MiraWindowShell(
        sidebar: AnyView(VStack(alignment: .leading) {
            Text("Mira").font(MiraTheme.Typography.title).padding()
            MiraSidebarRow(isSelected: true) { Label("New conversation", systemImage: "square.and.pencil") }
            Spacer()
        }.padding(MiraTheme.Spacing.sm)),
        detail: AnyView(Text("Start with an idea")
            .font(MiraTheme.Typography.welcome)
            .frame(maxWidth: .infinity, maxHeight: .infinity)),
        inspector: AnyView(Text("Execution details").padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)),
        title: "Mira", locale: Locale(identifier: "en"), isSettings: false,
        canInspect: true, showsInspector: $showsInspector,
        newConversation: {}
    )
    .frame(width: 850, height: 620)
    .containerBackground(MiraTheme.Colors.canvas, for: .window)
}

// The borderless selector uses a gray fill, a darker interaction fill, and a 28 pt height.
#Preview("Language select · Light") {
    @Previewable @State var language = "en"
    @Previewable @State var displayMode = "system"
    MiraSettingsPage {
        MiraSettingsHeader(title: "General", subtitle: "Customize Mira's display language and appearance.")
        MiraSettingsSection("Language") {
            MiraSettingsRow("Display Language", subtitle: "Changes apply immediately to all Mira windows and are saved for the next launch. Conversation content and model response language are not changed. macOS manages the language of system menus and file dialogs.") {
                MiraSettingsSelect(title: "Display Language", selection: $language, options: [
                    .init(id: "en", title: "English"),
                    .init(id: "zh-CN", title: "Chinese (Simplified)")
                ], identifier: "preview.language")
            }
        }
        MiraSettingsSection("Appearance") {
            MiraSettingsRow("Display Mode", subtitle: "Choose an appearance for all Mira windows, or follow your system setting.") {
                MiraSettingsSelect(title: "Display Mode", selection: $displayMode, options: [
                    .init(id: "dark", title: "Dark"), .init(id: "light", title: "Light"),
                    .init(id: "system", title: "Follow System")
                ], identifier: "preview.displayMode")
            }
        }
    }
    .frame(width: 850 - MiraTheme.Layout.sidebarIdeal, height: 620)
    .environment(\.locale, Locale(identifier: "en"))
    .preferredColorScheme(.light)
}

// Native selectors preserve dismissal, keyboard navigation, and selected/empty states.
#Preview("Select states · Unselected and empty") {
    @Previewable @State var unselected = ""
    @Previewable @State var empty = ""
    @Previewable @State var selected = "example"
    let options: [MiraSettingsSelect.Option] = [.init(id: "example", title: "Example Model")]
    MiraSettingsPage {
        MiraSettingsSection {
            MiraSettingsRow("Conversation model") {
                MiraSettingsSelect(title: "Model", selection: $unselected, options: options,
                                   identifier: "preview.select.unselected", placeholder: "Select a model")
            }
            MiraSettingsDivider()
            MiraSettingsRow("Memory extraction model") {
                MiraSettingsSelect(title: "Model", selection: $empty, options: [],
                                   identifier: "preview.select.empty", placeholder: "Select a model")
            }
            MiraSettingsDivider()
            MiraSettingsRow("Model") {
                MiraSettingsSelect(title: "Model", selection: $selected, options: options,
                                   identifier: "preview.select.clear", placeholder: "Select a model",
                                   clearSelectionTitle: "Clear Selection")
            }
        }
    }
    .frame(width: 670, height: 420)
    .environment(\.locale, Locale(identifier: "zh-CN"))
    .preferredColorScheme(.light)
}

#Preview("Select sizing · Minimum, capped, unbounded") {
    @Previewable @State var shortSelection = "short"
    @Previewable @State var longSelection = "long"
    let options: [MiraSettingsSelect.Option] = [
        .init(id: "short", title: "English"),
        .init(id: "long", title: "macOS manages the language of system menus and file dialogs.")
    ]
    MiraSettingsPage {
        MiraSettingsSection("Language") {
            // A short label retains the default minimum dimensions.
            MiraSettingsSelect(title: "Display Language", selection: $shortSelection,
                               options: options, identifier: "preview.select.minimum")
            // Only the trigger is capped; AppKit lays out the native menu.
            MiraSettingsSelect(title: "Display Language", selection: $longSelection,
                               options: options, identifier: "preview.select.capped",
                               maximumWidth: MiraTheme.Layout.selectMaxWidth)
            // An omitted trigger maximum allows the long label to take its intrinsic width.
            MiraSettingsSelect(title: "Display Language", selection: $longSelection,
                               options: options, identifier: "preview.select.unbounded")
        }
    }
    .frame(width: 850, height: 620)
    .environment(\.locale, Locale(identifier: "en"))
    .preferredColorScheme(.light)
}

// Only the native pop-up control appearance is styled, including its rotating chevron.
private struct MiraSettingsFieldPairPreview: View {
    @State private var value = "example-model"
    @State private var selection = "example-model"

    var body: some View {
        MiraSettingsPage {
            MiraSettingsSection {
                HStack(spacing: MiraTheme.Spacing.md) {
                    TextField("Model", text: $value)
                        .textFieldStyle(MiraSettingsTextFieldStyle())
                    MiraSettingsSelect(title: "Model", selection: $selection,
                                       options: [.init(id: "example-model", title: "Example Model")],
                                       identifier: "preview.select.fieldPair")
                }
            }
        }
        .frame(width: 520, height: 220)
    }
}

#Preview("Settings controls · Input and select · Light") {
    MiraSettingsFieldPairPreview().preferredColorScheme(.light)
}

#Preview("Settings controls · Input and select · Dark") {
    MiraSettingsFieldPairPreview().preferredColorScheme(.dark)
}

#Preview("Native select · Styled trigger and long menu") {
    @Previewable @State var selection = "model-60"
    let options = (1...100).map { index in
        // i18n-verbatim: Synthetic provider model identifiers for a long native menu.
        MiraSettingsSelect.Option(id: "model-\(index)", verbatimTitle: "example-model-\(index)")
    }
    MiraSettingsPage {
        VStack(alignment: .leading) {
            MiraSettingsSelect(title: "Model", selection: $selection, options: options,
                               identifier: "preview.select.long.top", maximumWidth: MiraTheme.Layout.selectMaxWidth)
            Spacer()
            HStack {
                Spacer()
                MiraSettingsSelect(title: "Model", selection: $selection, options: options,
                                   identifier: "preview.select.long.bottom", maximumWidth: MiraTheme.Layout.selectMaxWidth)
            }
        }
        .frame(height: 240)
    }
    .frame(width: 420, height: 340)
    .environment(\.locale, Locale(identifier: "en"))
    .preferredColorScheme(.light)
}

/// Synthetic renderer preview; no application runtime or library is opened.
private struct MiraMarkdownPreview: NSViewRepresentable {
    @Environment(\.locale) private var locale
    func makeNSView(context: Context) -> MiraMarkdownView { MiraMarkdownView() }
    func updateNSView(_ view: MiraMarkdownView, context: Context) {
        let source = "# A native reply\n\nSelectable **Markdown** with `inline code` and a [link](https://www.swift.org).\n\n- A stable paragraph\n- A wrapped list item\n\n```swift\nlet answer = 42\n```"
        let theme = MiraMarkdownStyle.theme(for: view.effectiveAppearance)
        view.apply(content: .init(markdown: source, theme: theme, locale: locale), source: source,
                   theme: theme, locale: locale, isStreaming: false, reduceMotion: true)
    }
}

#Preview("Markdown · Light") {
    MiraMarkdownPreview().frame(width: 500, height: 420).padding(24)
        .background(MiraTheme.Colors.canvas).preferredColorScheme(.light)
}

#Preview("Markdown · Dark") {
    MiraMarkdownPreview().frame(width: 360, height: 420).padding(24)
        .background(MiraTheme.Colors.canvas).preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh-CN"))
}

#Preview("Composer material over content") {
    @Previewable @State var draft = ""
    ZStack(alignment: .bottom) {
        ScrollView {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
                ForEach(0..<20) { _ in
                    Text("Start with an idea").font(MiraTheme.Typography.welcome)
                }
            }
            .frame(maxWidth: .infinity)
        }
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            TextField("Send a message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...8)
            HStack {
                Text("Local demo").font(MiraTheme.Typography.composerFootnote)
                Spacer()
                Button("Send", systemImage: "arrow.up") {}
                    .labelStyle(.iconOnly).buttonStyle(MiraCircleButtonStyle())
            }
        }
        .padding(MiraTheme.Spacing.lg)
        .modifier(MiraComposerGlass())
        .padding(.horizontal, MiraTheme.Spacing.xl)
        .padding(.bottom, MiraTheme.Layout.composerBottomInset)
    }
    .background(MiraTheme.Colors.canvas)
    .frame(width: 560, height: 480)
}
