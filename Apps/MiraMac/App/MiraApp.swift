import AppKit
import SwiftUI

@main
struct MiraApp: App {
    @NSApplicationDelegateAdaptor(MiraAppDelegate.self) private var delegate
    @State private var container: AppContainer
    @State private var settingsModel: SettingsModel
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = ""
    private var language: AppLanguage { .resolve(stored: languagePreference) }

    init() {
        let container = AppContainer()
        _container = State(initialValue: container)
        _settingsModel = State(initialValue: SettingsModel(container: container))
        delegate.container = container
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let library = container.library {
                    ConversationRoot(library: library, isDemo: container.isDemo)
                        .id(ObjectIdentifier(library))
                        .containerBackground(MiraTheme.Colors.canvas, for: .window)
                        .background { if container.isDemo { MiraDemoWindowSizing() } }
                } else {
                    LibraryStartupView(container: container)
                }
            }
            .task { await container.start() }
            .environment(\.locale, language.locale)
            .tint(MiraTheme.Colors.accent)
            .modifier(MiraAppAppearance())
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified)
        .commands { MiraSettingsCommands(locale: language.locale) }
        .commands {
            CommandGroup(replacing: .help) {
                Link(
                    L10n.string("Mira Documentation", locale: language.locale),
                    destination: URL(string: "https://github.com/alwynou/mira/tree/main/docs")!)
            }
        }

        Window("Settings", id: MiraSettingsWindow.id) {
            MiraSettingsRoot(model: settingsModel)
                .onChange(of: container.library.map(ObjectIdentifier.init)) { _, _ in settingsModel.close() }
                .environment(\.locale, language.locale)
                .modifier(MiraAppAppearance())
                .containerBackground(MiraTheme.Settings.canvas, for: .window)
        }
        .defaultSize(width: MiraTheme.Settings.windowWidth, height: MiraTheme.Settings.windowHeight)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .windowManagerRole(.associated)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// Demo runs get one deterministic window frame so UI fixtures never depend on
/// restored frames or window-manager sizing. Each window is sized at most once.
/// `--window-size WxH` overrides the default for narrow-layout fixtures.
private struct MiraDemoWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> MiraDemoWindowAnchor { MiraDemoWindowAnchor() }
    func updateNSView(_ nsView: MiraDemoWindowAnchor, context: Context) {}
}

private final class MiraDemoWindowAnchor: NSView {
    @MainActor private static var sizedWindows: Set<ObjectIdentifier> = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            guard let window, Self.sizedWindows.insert(ObjectIdentifier(window)).inserted,
                  let screen = window.screen ?? NSScreen.main else { return }
            let size = Self.requestedSize
            let visible = screen.visibleFrame
            window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true)
        }
    }

    private static let requestedSize: NSSize = {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--window-size"), arguments.indices.contains(flag + 1) else {
            return NSSize(width: 1100, height: 760)
        }
        let parts = arguments[flag + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { return NSSize(width: 1100, height: 760) }
        return NSSize(width: parts[0], height: parts[1])
    }()
}
