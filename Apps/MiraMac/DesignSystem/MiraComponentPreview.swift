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
        .containerBackground(.clear, for: .window)
    }
}

#Preview("Components · Light") {
    MiraComponentPreview().environment(\.locale, Locale(identifier: "en")).preferredColorScheme(.light)
}

#Preview("Components · Dark") {
    MiraComponentPreview().environment(\.locale, Locale(identifier: "en")).preferredColorScheme(.dark)
}
