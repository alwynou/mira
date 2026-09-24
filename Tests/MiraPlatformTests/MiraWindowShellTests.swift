import AppKit
import SwiftUI
import XCTest

@MainActor
final class MiraWindowShellTests: XCTestCase {
    func testInspectorPreservesWindowSidebarAndPresentationState() async throws {
        _ = NSApplication.shared
        let state = InspectorState()
        let shell = MiraWindowShell(
            sidebar: AnyView(Color.clear),
            detail: AnyView(Text(verbatim: String(repeating: "Synthetic content ", count: 100)).frame(idealWidth: 1_600)),
            inspector: AnyView(Text(verbatim: String(repeating: "Synthetic audit ", count: 100)).frame(idealWidth: 1_600)),
            title: "Mira", locale: Locale(identifier: "en"), canInspect: true,
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
        let dragToMaximum = NSPoint(x: dragStart.x - distanceToMaximum, y: dragStart.y)
        let mouseDrag = try mouseEvent(.leftMouseDragged, at: dragToMaximum)
        var sampledWhileHeld = false
        var postedOvershoot = false
        var postedRelease = false
        var trackingDeadline: ContinuousClock.Instant?
        // Wait for native tracking to consume each drag before sampling. A fixed
        // 150 ms release timer can fire before the first drag on a cold runner.
        let trackingTimer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !postedRelease else { return }
                if trackingDeadline == nil {
                    trackingDeadline = ContinuousClock.now.advanced(by: .seconds(10))
                }
                let inspector = controller.splitViewItems[2]
                let reachedMaximum = abs(inspector.viewController.view.frame.width - inspector.maximumThickness) <= 1
                let consumedOvershoot = postedOvershoot
                    && NSApp.currentEvent?.type == .leftMouseDragged
                    && NSApp.currentEvent?.locationInWindow == dragEnd
                let expired = ContinuousClock.now >= trackingDeadline!
                if !consumedOvershoot && !expired {
                    let point = reachedMaximum ? dragEnd : dragToMaximum
                    let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1)!
                    postedOvershoot = postedOvershoot || reachedMaximum
                    NSApp.postEvent(drag, atStart: false)
                    return
                }
                postedRelease = true
                sampledWhileHeld = consumedOvershoot
                XCTAssertTrue(consumedOvershoot, "Native tracking must consume the overshoot before the deadline.")
                let sidebar = controller.splitViewItems[0]
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
        RunLoop.main.add(trackingTimer, forMode: .eventTracking)
        NSApp.postEvent(mouseDrag, atStart: true)
        window.sendEvent(mouseDown)
        trackingTimer.invalidate()
        XCTAssertTrue(sampledWhileHeld, "The native divider must enter mouse tracking.")

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

        XCTAssertTrue(sidebar.canCollapse)
        XCTAssertFalse(sidebar.canCollapseFromWindowResize)
        XCTAssertTrue(try XCTUnwrap(window.toolbar).items.contains { $0.itemIdentifier == .toggleSidebar })
        sidebar.isCollapsed = true
        controller.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(sidebar.isCollapsed, "Conversation sidebar controls must remain usable.")
    }

    func testNativeConversationHeaderTracksTrafficLightsScrollDetailAndNativeControls() async throws {
        guard #available(macOS 26.1, *) else { return }
        _ = NSApplication.shared

        let detailProbe = NativeDetailScrollProbe()
        let state = InspectorState()
        let shell = MiraWindowShell(
            sidebar: AnyView(Text(verbatim: "Synthetic sidebar")),
            detail: AnyView(NativeDetailScrollView(probe: detailProbe)),
            inspector: AnyView(Text(verbatim: "Synthetic inspector")),
            title: "Synthetic conversation title", locale: Locale(identifier: "en"), canInspect: true,
            showsInspector: Binding(get: { state.visible }, set: { state.visible = $0 }),
            newConversation: {}
        )
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_050, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: shell
            .ignoresSafeArea()
            .frame(minWidth: 850, minHeight: 620)
            .containerBackground(MiraTheme.Colors.canvas, for: .window))
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        func shellController(in view: NSView) -> MiraWindowShell.Controller? {
            if let controller = view.nextResponder as? MiraWindowShell.Controller { return controller }
            return view.subviews.lazy.compactMap { shellController(in: $0) }.first
        }
        func descendants<T: NSView>(of view: NSView, matching type: T.Type) -> [T] {
            view.subviews.flatMap { child in
                let own = (child as? T).map { [$0] } ?? []
                return own + descendants(of: child, matching: type)
            }
        }
        func titleLabel(in view: NSView) -> NSTextField? {
            if let label = view as? NSTextField, label.accessibilityIdentifier() == "conversation.title" {
                return label
            }
            return view.subviews.lazy.compactMap { titleLabel(in: $0) }.first
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(650)) }
        func windowFrame(of view: NSView) -> NSRect { view.convert(view.bounds, to: window.contentView) }
        func assertHeaderGeometry(_ message: String) throws -> NSRect {
            let header = try XCTUnwrap(descendants(of: host.view, matching: MiraConversationHeaderView.self).first, message)
            let label = try XCTUnwrap(titleLabel(in: header), message)
            let close = try XCTUnwrap(window.standardWindowButton(.closeButton), message)
            let labelFrame = windowFrame(of: label)
            let closeFrame = windowFrame(of: close)
            let headerWindowFrame = header.convert(header.bounds, to: nil)
            XCTAssertEqual(header.bounds.height, MiraTheme.Layout.conversationHeaderHeight, accuracy: 0.5, message)
            XCTAssertEqual(headerWindowFrame.maxY, window.contentView?.convert(window.contentView!.bounds, to: nil).maxY ?? 0, accuracy: 3, message)
            XCTAssertEqual(labelFrame.midY, closeFrame.midY, accuracy: 2, message)
            XCTAssertGreaterThan(labelFrame.width, 0, message)
            let windowButtons = [window.standardWindowButton(.closeButton),
                                 window.standardWindowButton(.miniaturizeButton),
                                 window.standardWindowButton(.zoomButton)].compactMap { $0 }
            let sidebarButton = window.toolbar?.items.first { $0.itemIdentifier == .toggleSidebar }?.view
            let occupiedMaxX = max(windowButtons.map { windowFrame(of: $0).maxX }.max() ?? 0,
                                   sidebarButton.map { windowFrame(of: $0).maxX } ?? 0)
            let actionIDs = ["conversation.new", "conversation.inspector", "conversation.knowledge", "memory.new", "knowledge.import"]
            let actionMinX = window.toolbar?.items.filter { actionIDs.contains($0.itemIdentifier.rawValue) }
                .compactMap { $0.view }
                .map { windowFrame(of: $0).minX }
                .min() ?? window.contentView!.bounds.maxX
            let detailRect = detailView.convert(detailView.safeAreaRect, to: window.contentView)
            XCTAssertGreaterThanOrEqual(labelFrame.minX, occupiedMaxX + MiraTheme.Spacing.md - 1, message)
            XCTAssertLessThanOrEqual(labelFrame.maxX,
                                     min(actionMinX, detailRect.maxX) - MiraTheme.Spacing.lg + 1, message)
            return labelFrame
        }

        try await settle()
        let controller = try XCTUnwrap(shellController(in: host.view))
        let sidebar = controller.splitViewItems[0]
        let inspector = controller.splitViewItems[2]
        let detailView = controller.splitViewItems[1].viewController.view
        let nativeScrollView = try XCTUnwrap(detailProbe.scrollView, "The detail fixture must retain its native scroll view.")
        XCTAssertTrue(nativeScrollView.isDescendant(of: detailView))
        XCTAssertFalse(detailView === nativeScrollView)
        XCTAssertFalse(sidebar.isCollapsed)
        // A cold window can publish toolbar items before AppKit has attached and
        // positioned their views. Wait on those native prerequisites, not on the
        // title geometry under test, and do not force the header to lay out.
        let initialActions = ["conversation.new", "conversation.inspector", "conversation.knowledge"]
        func initialToolbarIsReady() -> Bool {
            let views = window.toolbar?.items.filter { initialActions.contains($0.itemIdentifier.rawValue) }
                .compactMap(\.view) ?? []
            return views.count == initialActions.count && views.allSatisfy {
                $0.window === window && $0.bounds.width > 0 && windowFrame(of: $0).minX > 0
            }
        }
        let toolbarDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !initialToolbarIsReady() && ContinuousClock.now < toolbarDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(initialToolbarIsReady(), "Initial native toolbar views must be installed and positioned.")
        try await settle()
        let initialTitleFrame = try assertHeaderGeometry("Initial native header geometry")
        let sidebarView = sidebar.viewController.view
        XCTAssertLessThanOrEqual(sidebarView.convert(sidebarView.safeAreaRect, to: nil).maxY,
                                 window.contentLayoutRect.maxY + 1,
                                 "Sidebar content must stay below window controls after titlebar inset cancellation.")

        state.visible = true
        controller.update(shell)
        try await settle()
        XCTAssertFalse(inspector.isCollapsed)
        XCTAssertGreaterThanOrEqual(inspector.viewController.view.frame.width, inspector.minimumThickness - 1)

        let nativeIDs: Set<String> = [
            NSToolbarItem.Identifier.toggleSidebar.rawValue,
            "conversation.new", "conversation.inspector", "conversation.knowledge"
        ]
        let nativeItems = try XCTUnwrap(window.toolbar?.items.filter {
            nativeIDs.contains($0.itemIdentifier.rawValue)
        })
        XCTAssertEqual(nativeItems.count, 4)
        func assertNativeControls(_ message: String) {
            XCTAssertTrue(nativeItems.allSatisfy {
                $0.view?.isHidden == false && ($0.view?.frame.width ?? 0) > 0
            }, message)
        }
        assertNativeControls("Native sidebar and action controls must be visible while expanded.")

        // Management destinations replace trailing toolbar items while retaining
        // the conversation host. Returning must relayout against installed controls.
        for cycle in 0..<3 {
            var memories = shell
            memories.title = "Memories"
            memories.addMemory = {}
            controller.update(memories)
            try await settle()
            _ = try assertHeaderGeometry("Memory destination in cycle \(cycle)")

            controller.update(shell)
            try await settle()
            _ = try assertHeaderGeometry("Conversation after Memory in cycle \(cycle)")

            var knowledge = shell
            knowledge.title = "Knowledge"
            knowledge.importKnowledge = {}
            controller.update(knowledge)
            try await settle()
            _ = try assertHeaderGeometry("Knowledge destination in cycle \(cycle)")

            controller.update(shell)
            try await settle()
            _ = try assertHeaderGeometry("Conversation after Knowledge in cycle \(cycle)")
            assertNativeControls("Conversation controls after management navigation")
        }

        window.setFrame(NSRect(x: 100, y: 100, width: 850, height: 700), display: true)
        try await settle()
        let resizedTitleFrame = try assertHeaderGeometry("Header geometry after 1050 to 850 resize")
        XCTAssertGreaterThan(resizedTitleFrame.width, 0)
        XCTAssertEqual(window.frame.width, 850, accuracy: 1)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        sidebar.animator().isCollapsed = true
        var collapseSamples: [CGFloat] = [resizedTitleFrame.minX]
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(35))
            collapseSamples.append(try assertHeaderGeometry("Header during sidebar collapse").minX)
        }
        try await settle()
        let collapsedTitleFrame = try assertHeaderGeometry("Header after sidebar collapse")
        XCTAssertTrue(sidebar.isCollapsed)
        assertNativeControls("Native sidebar and action controls must remain visible while collapsed.")
        XCTAssertLessThan(collapsedTitleFrame.minX, resizedTitleFrame.minX - 1)
        collapseSamples.append(collapsedTitleFrame.minX)
        XCTAssertGreaterThanOrEqual(Set(collapseSamples.map { Int(($0 * 10).rounded()) }).count, 3,
                                    "Sidebar collapse must expose intermediate title positions: \(collapseSamples)")
        XCTAssertTrue(zip(collapseSamples, collapseSamples.dropFirst()).allSatisfy { $0 >= $1 - 4 },
                      "Header leading edge must move continuously toward the collapsed sidebar position: \(collapseSamples)")

        sidebar.animator().isCollapsed = false
        var expandSamples: [CGFloat] = [collapsedTitleFrame.minX]
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(35))
            expandSamples.append(try assertHeaderGeometry("Header during sidebar expansion").minX)
        }
        try await settle()
        let expandedTitleFrame = try assertHeaderGeometry("Header after sidebar expansion")
        XCTAssertFalse(sidebar.isCollapsed)
        assertNativeControls("Native sidebar and action controls must remain visible after expansion.")
        XCTAssertGreaterThan(expandedTitleFrame.minX, collapsedTitleFrame.minX + 1)
        expandSamples.append(expandedTitleFrame.minX)
        XCTAssertGreaterThanOrEqual(Set(expandSamples.map { Int(($0 * 10).rounded()) }).count, 3,
                                    "Sidebar expansion must expose intermediate title positions: \(expandSamples)")
        XCTAssertTrue(zip(expandSamples, expandSamples.dropFirst()).allSatisfy { $0 <= $1 + 4 },
                      "Header leading edge must move continuously toward the expanded sidebar position: \(expandSamples)")
        XCTAssertEqual(expandedTitleFrame.minX, initialTitleFrame.minX, accuracy: 8)
    }
}

@MainActor
private final class InspectorState {
    var visible = false
}

@MainActor
private final class NativeDetailScrollProbe {
    var scrollView: NSScrollView?
}

private struct NativeDetailScrollView: NSViewRepresentable {
    let probe: NativeDetailScrollProbe

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 2_000))
        document.string = String(repeating: "Synthetic transcript\n", count: 80)
        scrollView.documentView = document
        probe.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
