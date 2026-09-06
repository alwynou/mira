import AppKit
import Observation
import SwiftUI
import Testing

@MainActor
@Suite("Native transcript scroll motion", .serialized)
struct TranscriptScrollAnimationTests {
    @Test func changingTargetsProducesIntermediateOffsetsWithoutReversing() async throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        try await Task.sleep(for: .milliseconds(150))
        fixture.probe.offsets = []
        TranscriptScrollAnimation.perform(animated: true) { fixture.probe.position.scrollTo(y: 500) }
        try await Task.sleep(for: .milliseconds(100))
        TranscriptScrollAnimation.perform(animated: true) { fixture.probe.position.scrollTo(y: 800) }
        try await Task.sleep(for: .milliseconds(500))
        let offsets = fixture.probe.offsets
        #expect(offsets.filter { $0 > 1 && $0 < 799 }.count >= 3)
        #expect(abs((offsets.last ?? 0) - 800) < 2)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $1 >= $0 - 1 })
    }

    @Test func immediatePlacementDoesNotAnimate() async throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        try await Task.sleep(for: .milliseconds(150))
        fixture.probe.offsets = []
        TranscriptScrollAnimation.perform(animated: false) { fixture.probe.position.scrollTo(y: 500) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs((fixture.probe.offsets.last ?? 0) - 500) < 2)
        #expect(!fixture.probe.offsets.contains { $0 > 1 && $0 < 499 })
    }

    @MainActor private final class Fixture {
        let probe = Probe()
        let window: NSWindow

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ScrollFixture(probe: probe))
            window.orderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @MainActor @Observable final class Probe {
        var position = ScrollPosition(y: 0)
        @ObservationIgnored var offsets: [CGFloat] = []
    }

    private struct ScrollFixture: View {
        @Bindable var probe: Probe
        var body: some View {
            ScrollView {
                Color.clear.frame(height: 1_600)
            }
            .scrollPosition($probe.position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                probe.offsets.append(offset)
            }
        }
    }
}
