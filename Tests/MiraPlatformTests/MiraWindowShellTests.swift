import AppKit
import SwiftUI
import XCTest

@MainActor
final class MiraWindowShellTests: XCTestCase {
    func testInspectorPreservesWindowSidebarAndPresentationState() async throws {
        _ = NSApplication.shared
        let state = InspectorState()
        var shell = MiraWindowShell(
            sidebar: AnyView(Color.clear),
            detail: AnyView(Text(verbatim: String(repeating: "Synthetic content ", count: 100)).frame(idealWidth: 1_600)),
            inspector: AnyView(Text(verbatim: String(repeating: "Synthetic audit ", count: 100)).frame(idealWidth: 1_600)),
            title: "Mira", locale: Locale(identifier: "en"), isSettings: false, canInspect: true,
            showsInspector: Binding(get: { state.visible }, set: { state.visible = $0 }),
            newConversation: {}
        )
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 850, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: shell
            .ignoresSafeArea()
            .frame(minWidth: 850, minHeight: 620)
            .containerBackground(MiraTheme.Colors.canvas, for: .window))
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.setFrame(NSRect(x: 100, y: 100, width: 850, height: 700), display: true)
        try await Task.sleep(for: .milliseconds(300))
        func shellController(in view: NSView) -> MiraWindowShell.Controller? {
            if let controller = view.nextResponder as? MiraWindowShell.Controller { return controller }
            return view.subviews.lazy.compactMap { shellController(in: $0) }.first
        }
        let controller = try XCTUnwrap(shellController(in: host.view))
        let sidebar = controller.splitViewItems[0]
        let inspector = controller.splitViewItems[2]
        let sidebarWidth = sidebar.viewController.view.frame.width

        state.visible = true
        controller.update(shell)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(window.frame.width, 850, accuracy: 1)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertEqual(sidebar.viewController.view.frame.width, sidebarWidth, accuracy: 1)
        XCTAssertFalse(inspector.isCollapsed)
        XCTAssertGreaterThanOrEqual(inspector.viewController.view.frame.width, 180)
        let sidebarFrame = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: controller.view)
        let detailView = controller.splitViewItems[1].viewController.view
        let detailFrame = detailView.convert(detailView.safeAreaRect, to: controller.view)
        let inspectorFrame = inspector.viewController.view.convert(inspector.viewController.view.bounds, to: controller.view)
        XCTAssertGreaterThanOrEqual(sidebarFrame.minX, 0)
        XCTAssertLessThanOrEqual(sidebarFrame.minX, 16, "The sidebar must remain at the window's leading edge.")
        XCTAssertGreaterThan(detailFrame.width, 0)
        XCTAssertGreaterThanOrEqual(detailFrame.minX, sidebarFrame.maxX - 1)
        XCTAssertLessThanOrEqual(detailFrame.maxX, inspectorFrame.minX + 1)

        // Resizing execution details must only redistribute its width with the conversation.
        for requestedWidth: CGFloat in [380, 480, 560, 700, 180] {
            let width = min(requestedWidth, inspector.maximumThickness)
            controller.splitView.setPosition(controller.splitView.bounds.width - requestedWidth - controller.splitView.dividerThickness,
                                             ofDividerAt: 1)
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let resizedSidebar = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: controller.view)
            let resizedInspector = inspector.viewController.view.convert(inspector.viewController.view.bounds, to: controller.view)
            XCTAssertEqual(window.frame.width, 850, accuracy: 1)
            XCTAssertEqual(resizedSidebar.minX, sidebarFrame.minX, accuracy: 1)
            XCTAssertEqual(resizedSidebar.width, sidebarFrame.width, accuracy: 1)
            XCTAssertEqual(resizedInspector.width, width, accuracy: 1)
            XCTAssertEqual(resizedInspector.maxX, controller.view.bounds.maxX, accuracy: 1)
        }

        // Sample inside AppKit's tracking loop, before mouse-up can repair overshoot.
        let splitView = controller.splitView
        let dragStart = inspector.viewController.view.convert(
            NSPoint(x: -splitView.dividerThickness / 2, y: 120), to: nil)
        let dragEnd = NSPoint(x: dragStart.x - 600, y: dragStart.y)
        func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let mouseDown = try mouseEvent(.leftMouseDown, at: dragStart)
        let distanceToMaximum = inspector.maximumThickness - inspector.viewController.view.frame.width
        let mouseDrag = try mouseEvent(.leftMouseDragged, at: NSPoint(x: dragStart.x - distanceToMaximum, y: dragStart.y))
        let overshootTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: dragEnd, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.postEvent(drag, atStart: false)
            }
        }
        var sampledWhileHeld = false
        let releaseTimer = Timer(timeInterval: 0.15, repeats: false) { _ in
            MainActor.assumeIsolated {
                sampledWhileHeld = true
                let sidebar = controller.splitViewItems[0]
                let inspector = controller.splitViewItems[2]
                let heldSidebar = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: controller.view)
                let heldInspector = inspector.viewController.view.convert(inspector.viewController.view.bounds, to: controller.view)
                let heldShell = controller.view.convert(controller.view.bounds, to: host.view)
                XCTAssertEqual(window.frame.width, 850, accuracy: 1)
                XCTAssertEqual(heldShell.minX, 0, accuracy: 1)
                XCTAssertEqual(heldShell.width, host.view.bounds.width, accuracy: 1)
                XCTAssertEqual(heldSidebar.minX, sidebarFrame.minX, accuracy: 1)
                XCTAssertEqual(heldSidebar.width, sidebarFrame.width, accuracy: 1)
                XCTAssertEqual(heldInspector.width, inspector.maximumThickness, accuracy: 1)
                XCTAssertEqual(heldInspector.maxX, controller.view.bounds.maxX, accuracy: 1)
                let mouseUp = NSEvent.mouseEvent(with: .leftMouseUp, location: dragEnd, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 0)!
                NSApp.postEvent(mouseUp, atStart: false)
            }
        }
        RunLoop.main.add(releaseTimer, forMode: .eventTracking)
        RunLoop.main.add(overshootTimer, forMode: .eventTracking)
        NSApp.postEvent(mouseDrag, atStart: true)
        window.sendEvent(mouseDown)
        releaseTimer.invalidate()
        overshootTimer.invalidate()
        XCTAssertTrue(sampledWhileHeld, "The native divider must enter mouse tracking.")

        shell.isSettings = true
        controller.update(shell)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(inspector.isCollapsed)
        XCTAssertTrue(state.visible, "Settings hides the inspector without discarding the conversation preference.")
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertFalse(sidebar.canCollapse)
        XCTAssertEqual(sidebar.minimumThickness, 180)
        XCTAssertEqual(sidebar.maximumThickness, 180)
        XCTAssertEqual(sidebar.viewController.view.frame.width, 180, accuracy: 1)
        XCTAssertFalse(try XCTUnwrap(window.toolbar).items.contains { $0.itemIdentifier == .toggleSidebar })
        controller.toggleSidebar(nil)
        XCTAssertFalse(sidebar.isCollapsed, "Settings must ignore the sidebar command.")
        shell.isSettings = false
        controller.update(shell)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(inspector.isCollapsed)
        XCTAssertEqual(sidebar.viewController.view.frame.width, sidebarFrame.width, accuracy: 1,
                       "Leaving settings restores the conversation width.")

        // Native divider collapse must update the SwiftUI presentation binding.
        inspector.isCollapsed = true
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(state.visible)
        state.visible = true
        controller.update(shell)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(inspector.isCollapsed)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertEqual(window.frame.width, 850, accuracy: 1)

        // Opening settings from a collapsed conversation must make navigation reachable.
        sidebar.isCollapsed = true
        shell.isSettings = true
        controller.update(shell)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertFalse(controller.splitView(controller.splitView, canCollapseSubview: sidebar.viewController.view))
        let sidebarCommand = NSMenuItem(title: "Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateUserInterfaceItem(sidebarCommand))
        controller.update(shell)
        shell.isSettings = false
        controller.update(shell)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(sidebar.isCollapsed, "Returning restores the conversation sidebar preference.")
        XCTAssertTrue(sidebar.canCollapse)
        XCTAssertFalse(sidebar.canCollapseFromWindowResize)
        XCTAssertTrue(try XCTUnwrap(window.toolbar).items.contains { $0.itemIdentifier == .toggleSidebar })
        controller.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(sidebar.isCollapsed, "Conversation sidebar controls must remain usable.")
    }
}

@MainActor
private final class InspectorState {
    var visible = false
}
