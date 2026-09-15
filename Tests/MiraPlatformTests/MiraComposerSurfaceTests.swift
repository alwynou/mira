import AppKit
import Testing

@MainActor
@Suite("Composer window-local surface")
struct MiraComposerSurfaceTests {
    @Test func materialSamplesOnlyCurrentWindowAndDoesNotInterceptInput() {
        _ = NSApplication.shared
        let backdrop = MiraComposerBackdropView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        #expect(backdrop.blendingMode == .withinWindow)
        #expect(backdrop.hitTest(CGPoint(x: 20, y: 20)) == nil)
        #expect((backdrop.layer?.shadowOpacity ?? 0) == 0)
    }
}
