import AppKit
import SwiftUI

/// AppKit owns column sizing and window chrome; SwiftUI owns each pane’s content.
struct MiraWindowShell: NSViewControllerRepresentable {
    var sidebar: AnyView
    var detail: AnyView
    var inspector: AnyView
    var title: String
    var locale: Locale
    var isSettings: Bool
    var canInspect: Bool
    @Binding var showsInspector: Bool
    var newConversation: () -> Void
    var returnToConversation: () -> Void

    func makeNSViewController(context: Context) -> Controller { Controller(configuration: self) }
    func updateNSViewController(_ controller: Controller, context: Context) { controller.update(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Controller, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        // The window allocates this shell's viewport. Transient native drag sizes
        // must not become a new SwiftUI ideal size that shrinks and centers it.
        return CGSize(width: width, height: height)
    }

    @MainActor final class Controller: NSSplitViewController, NSToolbarDelegate {
        private let sidebarHost: NSHostingController<AnyView>
        private let detailHost: NSHostingController<AnyView>
        private let inspectorHost: NSHostingController<AnyView>
        private var sidebarItem: NSSplitViewItem!
        private var inspectorItem: NSSplitViewItem!
        private var configuration: MiraWindowShell
        private weak var installedWindow: NSWindow?
        private var initialPositionSet = false
        private var updatingFromSwiftUI = false
        private var inspectorUpdate: Task<Void, Never>?
        private var sidebarObservation: NSKeyValueObservation?
        private var inspectorObservation: NSKeyValueObservation?
        private let nativeToolbar = NSToolbar(identifier: "mira.window.toolbar")
        private var cachedItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
        private static let separator = NSToolbarItem.Identifier("mira.sidebar.separator")
        private static let newItem = NSToolbarItem.Identifier("conversation.new")
        private static let inspectorID = NSToolbarItem.Identifier("conversation.inspector")
        private static let knowledge = NSToolbarItem.Identifier("conversation.knowledge")
        private static let returnItem = NSToolbarItem.Identifier("settings.return")

        init(configuration: MiraWindowShell) {
            self.configuration = configuration
            sidebarHost = NSHostingController(rootView: Self.fitted(configuration.sidebar))
            detailHost = NSHostingController(rootView: Self.fitted(configuration.detail))
            inspectorHost = NSHostingController(rootView: AnyView(EmptyView()))
            super.init(nibName: nil, bundle: nil)
            // The split items, not hosted content measurements, own all column widths.
            for host in [sidebarHost, detailHost, inspectorHost] { host.sizingOptions = [] }
            sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
            sidebarItem.minimumThickness = MiraTheme.Layout.sidebarMin
            sidebarItem.maximumThickness = MiraTheme.Layout.sidebarMax
            sidebarItem.canCollapseFromWindowResize = false
            sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            // Keep pane holding priorities below AppKit's divider-drag priority (490).
            sidebarItem.holdingPriority = .defaultLow
            let detailItem = NSSplitViewItem(viewController: detailHost)
            detailItem.minimumThickness = 0
            detailItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue - 1)
            detailItem.titlebarSeparatorStyle = .none
            if #available(macOS 26.0, *) {
                detailItem.automaticallyAdjustsSafeAreaInsets = true
            }
            inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
            inspectorItem.minimumThickness = 180
            inspectorItem.maximumThickness = 480
            inspectorItem.preferredThicknessFraction = 340 / 1100
            inspectorItem.holdingPriority = .defaultLow
            inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            inspectorItem.isCollapsed = true
            addSplitViewItem(sidebarItem)
            addSplitViewItem(detailItem)
            addSplitViewItem(inspectorItem)
            nativeToolbar.delegate = self
            nativeToolbar.displayMode = .iconOnly
            nativeToolbar.allowsUserCustomization = false
            observeCollapsedState()
        }

        required init?(coder: NSCoder) { fatalError("Storyboard initialization is unsupported.") }

        override func viewDidAppear() {
            super.viewDidAppear()
            installToolbar()
            if !initialPositionSet {
                initialPositionSet = true
                splitView.setPosition(MiraTheme.Layout.sidebarIdeal, ofDividerAt: 0)
            }
        }

        private func installToolbar() {
            guard let window = view.window else { return }
            if installedWindow !== window {
                installedWindow = window
                window.toolbar = nativeToolbar
                window.toolbarStyle = .unified
                window.titlebarSeparatorStyle = .none
                window.titlebarAppearsTransparent = true
            }
            updateWindow()
        }

        private static func fitted(_ content: AnyView) -> AnyView {
            AnyView(content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped())
        }

        func update(_ configuration: MiraWindowShell) {
            updatingFromSwiftUI = true
            defer { updatingFromSwiftUI = false }
            self.configuration = configuration
            sidebarHost.rootView = Self.fitted(configuration.sidebar)
            detailHost.rootView = Self.fitted(configuration.detail)
            let visible = configuration.showsInspector && !configuration.isSettings
            inspectorHost.rootView = visible ? Self.fitted(configuration.inspector) : AnyView(EmptyView())
            inspectorUpdate?.cancel()
            if inspectorItem.isCollapsed == visible {
                // Begin native constraint animation after SwiftUI finishes installing
                // the new hosted content, avoiding a recursive safe-area layout.
                inspectorUpdate = Task { @MainActor [weak self] in
                    guard !Task.isCancelled, let self else { return }
                    self.updatingFromSwiftUI = true
                    defer { self.updatingFromSwiftUI = false }
                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        self.inspectorItem.isCollapsed = !visible
                    } else {
                        self.inspectorItem.animator().isCollapsed = !visible
                    }
                }
            }
            updateWindow()
        }

        private func observeCollapsedState() {
            sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateWindow() }
            }
            inspectorObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated {
                    guard let self, !self.updatingFromSwiftUI, !self.configuration.isSettings,
                          let collapsed = change.newValue else { return }
                    // A divider gesture is a presentation change too. Publish outside a SwiftUI update.
                    Task { @MainActor [weak self] in
                        guard let self, self.inspectorItem.isCollapsed == collapsed,
                              !self.configuration.isSettings,
                              self.configuration.showsInspector == collapsed else { return }
                        self.configuration.showsInspector = !collapsed
                    }
                }
            }
        }

        private var desiredItems: [NSToolbarItem.Identifier] {
            let leading: [NSToolbarItem.Identifier] = [.toggleSidebar, Self.separator, .flexibleSpace]
            if configuration.isSettings {
                return leading + (sidebarItem.isCollapsed ? [Self.returnItem] : [])
            }
            return leading + [Self.newItem, Self.inspectorID, Self.knowledge]
        }

        private func updateWindow() {
            installedWindow?.title = configuration.title
            installedWindow?.titleVisibility = configuration.isSettings ? .hidden : .visible
            let desired = desiredItems
            if nativeToolbar.items.map(\.itemIdentifier) != desired {
                for i in nativeToolbar.items.indices.reversed() where !desired.contains(nativeToolbar.items[i].itemIdentifier) {
                    nativeToolbar.removeItem(at: i)
                }
                for (i, id) in desired.enumerated() where !nativeToolbar.items.contains(where: { $0.itemIdentifier == id }) {
                    nativeToolbar.insertItem(withItemIdentifier: id, at: i)
                }
            }
            for (id, item) in cachedItems {
                let label: String
                switch id {
                case Self.newItem: label = "New conversation"
                case Self.inspectorID: label = "Execution details"
                case Self.knowledge: label = "Knowledge"
                case Self.returnItem: label = "Back to Mira"
                default: continue
                }
                let text = L10n.string(label, locale: configuration.locale)
                if item.label != text { item.label = text; item.paletteLabel = text }
                item.toolTip = id == Self.knowledge ? L10n.string("Not implemented yet", locale: configuration.locale) : text
                item.isEnabled = id != Self.inspectorID || configuration.canInspect
                if let button = item.view as? NSButton {
                    button.setAccessibilityLabel(text)
                    button.toolTip = item.toolTip
                    button.isEnabled = item.isEnabled
                }
            }
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { desiredItems }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [.toggleSidebar, Self.separator, .flexibleSpace, Self.newItem, Self.inspectorID, Self.knowledge, Self.returnItem]
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            if let cached = cachedItems[id] { return cached }
            if id == Self.separator { return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 0) }
            let label: String
            let symbol: String
            let action: Selector
            switch id {
            case Self.newItem: (label, symbol, action) = ("New conversation", "square.and.pencil", #selector(newConversation))
            case Self.inspectorID: (label, symbol, action) = ("Execution details", "sidebar.right", #selector(toggleExecutionInspector))
            case Self.knowledge: (label, symbol, action) = ("Knowledge", "book.closed", #selector(openKnowledge))
            case Self.returnItem: (label, symbol, action) = ("Back to Mira", "arrow.left", #selector(returnToConversation))
            default: return nil
            }
            let item = NSToolbarItem(itemIdentifier: id)
            item.autovalidates = false
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: action)
            button.setAccessibilityIdentifier(id.rawValue)
            button.imagePosition = .imageOnly
            if id == Self.newItem { button.keyEquivalent = "n"; button.keyEquivalentModifierMask = .command }
            button.bezelStyle = .texturedRounded
            item.view = button
            item.label = L10n.string(label, locale: configuration.locale)
            item.paletteLabel = item.label
            item.target = self
            item.action = action
            item.isEnabled = id != Self.inspectorID || configuration.canInspect
            button.isEnabled = item.isEnabled
            cachedItems[id] = item
            return item
        }

        @objc private func newConversation() { configuration.newConversation() }
        @objc private func toggleExecutionInspector() { configuration.showsInspector.toggle() }
        @objc private func openKnowledge() {}
        @objc private func returnToConversation() { configuration.returnToConversation() }
    }
}
