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
                MiraSurface(cornerRadius: MiraTheme.Radius.composer) {
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                        Text("Send a message…").foregroundStyle(MiraTheme.Colors.secondaryText)
                        HStack {
                            Text("Use default model").font(MiraTheme.Typography.caption)
                            Spacer()
                            Button("Stop", systemImage: "stop.fill") {}
                                .labelStyle(.iconOnly).buttonStyle(MiraCircleButtonStyle())
                        }
                    }
                    .padding(MiraTheme.Spacing.lg)
                    .frame(width: 360)
                }
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

// Settings previews include the 64 pt top inset and 32 pt header-to-content gap.
#Preview("Settings · Light") {
    @Previewable @State var search = ""
    @Previewable @State var enabled = true
    MiraSettingsPage {
        MiraSettingsHeader(title: "Providers", subtitle: "Manage provider connections and models.")
        MiraSettingsSearchField(prompt: "Search providers", text: $search)
        MiraSettingsSection("Providers") {
            MiraSettingsRow("Active") { Toggle("Active", isOn: $enabled).labelsHidden().toggleStyle(.switch) }
            MiraSettingsDivider()
            MiraSettingsRow("Default Models") { Button("Configure") {} }
        }
    }
    .frame(width: 850 - MiraTheme.Layout.sidebarIdeal, height: 620)
    .preferredColorScheme(.light)
}

#Preview("Settings · Dark") {
    @Previewable @State var search = ""
    MiraSettingsPage {
        MiraSettingsHeader(title: "General", subtitle: "Customize Mira's display language.")
        MiraSettingsSection("Language") {
            MiraSettingsRow("Display Language") { Text("English") }
            MiraSettingsDivider()
            Text("macOS manages the language of system menus and file dialogs.")
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
        }
    }
    .frame(width: 850 - MiraTheme.Layout.sidebarIdeal, height: 620)
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
