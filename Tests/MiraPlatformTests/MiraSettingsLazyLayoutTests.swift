import AppKit
import SwiftUI
import Testing

@MainActor
@Suite("Lazy provider settings", .serialized)
struct MiraSettingsLazyLayoutTests {
    @Test("a thousand model rows only realize the visible window and prefetch region")
    func largeCollectionsStayLazy() {
        _ = NSApplication.shared
        let small = measure(count: 40)
        let large = measure(count: 1_000)
        print("Provider row realization: 40=\(small), 1000=\(large)")
        #expect(small > 0)
        #expect(large > 0)
        #expect(large < 40, "Offscreen models must not be eagerly laid out by a grouped section.")
        #expect(large <= small + 8, "Initial work must remain bounded as the collection grows.")
    }

    @Test("production model rows keep programmatic scrolling monotonic")
    func productionRowsScrollWithoutOffsetJumps() {
        _ = NSApplication.shared
        let measurement = measureRoundTrip(count: 100)
        print("Production provider scroll: \(measurement)")
        #expect(measurement.samples >= 150)
        #expect(measurement.offsetsMonotonic)
        #expect(measurement.realized > 0)
    }

    private func measureRoundTrip(count: Int) -> ScrollMeasurement {
        let counter = SettingsRowCounter()
        let host = NSHostingView(rootView: RealisticModelCollectionFixture(count: count, counter: counter))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()
        guard let scrollView = host.descendantScrollView, let documentView = scrollView.documentView else {
            Issue.record("The fixture did not install an NSScrollView")
            return ScrollMeasurement()
        }
        let clipView = scrollView.contentView
        let maximumY = max(0, documentView.bounds.height - clipView.bounds.height)
        let step: CGFloat = 30
        let down = Array(stride(from: clipView.bounds.origin.y, through: maximumY, by: step))
        let up = Array(stride(from: maximumY, through: clipView.bounds.origin.y, by: -step))
        var previousY = clipView.bounds.origin.y
        var monotonic = true
        var times: [TimeInterval] = []
        for position in down + up {
            let start = Date()
            clipView.setBoundsOrigin(NSPoint(x: 0, y: position))
            host.layoutSubtreeIfNeeded()
            times.append(Date().timeIntervalSince(start))
            let currentY = clipView.bounds.origin.y
            monotonic = monotonic && (position >= previousY
                ? currentY + 0.5 >= previousY
                : currentY - 0.5 <= previousY)
            previousY = currentY
        }
        let sorted = times.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return ScrollMeasurement(realized: counter.realized.count,
                                 samples: times.count, p95: p95, worst: sorted.last ?? 0,
                                 offsetsMonotonic: monotonic)
    }

    private func measure(count: Int) -> Int {
        let counter = SettingsRowCounter()
        let host = NSHostingView(rootView: SettingsCollectionFixture(count: count, counter: counter))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 552, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()
        return counter.realized.count
    }
}

private extension NSView {
    var descendantScrollView: NSScrollView? {
        if let scrollView = self as? NSScrollView { return scrollView }
        for child in subviews {
            if let scrollView = child.descendantScrollView { return scrollView }
        }
        return nil
    }
}

@MainActor
private final class SettingsRowCounter {
    var realized = Set<Int>()
}

private struct ScrollMeasurement: CustomStringConvertible {
    let realized: Int
    let samples: Int
    let p95: TimeInterval
    let worst: TimeInterval
    let offsetsMonotonic: Bool

    init(realized: Int = 0, samples: Int = 0, p95: TimeInterval = 0,
         worst: TimeInterval = 0, offsetsMonotonic: Bool = true) {
        self.realized = realized; self.samples = samples
        self.p95 = p95; self.worst = worst; self.offsetsMonotonic = offsetsMonotonic
    }

    var description: String {
        "realized=\(realized), samples=\(samples), p95Ms=\(p95 * 1_000), worstMs=\(worst * 1_000), monotonic=\(offsetsMonotonic)"
    }
}

private struct SettingsCollectionFixture: View {
    let count: Int
    let counter: SettingsRowCounter

    var body: some View {
        MiraSettingsLazyPage {
            MiraSettingsSection("Provider Models", isCollection: true) {
                ForEach(0..<count, id: \.self) { id in
                    MiraSettingsLazyRow(isFirst: id == 0, isLast: id == count - 1) {
                        CountedSettingsRow(id: id, counter: counter)
                    }
                }
            }
        }
    }
}

private struct RealisticModelCollectionFixture: View {
    let count: Int
    let counter: SettingsRowCounter

    var body: some View {
        MiraSettingsLazyPage {
            MiraSettingsSection("Provider Models", isCollection: true) {
                ForEach(0..<count, id: \.self) { id in
                    MiraSettingsLazyRow(isFirst: id == 0, isLast: id == count - 1) {
                        CountedProviderModelRow(id: id, counter: counter)
                    }
                }
            }
        }
    }
}

private struct CountedProviderModelRow: View {
    let id: Int
    let counter: SettingsRowCounter

    var body: some View {
        let _ = counter.realized.insert(id)
        MiraProviderModelRow(
            name: id.isMultiple(of: 4) ? "A model with a deliberately long display name \(id)" : "Model \(id)",
            modelID: id.isMultiple(of: 3) ? "synthetic/very-long-model-family-name-\(id)-with-version" : "synthetic/model-\(id)",
            pricing: id.isMultiple(of: 5) ? .init(input: "0.50", output: "1.20") : nil,
            providerID: nil,
            supportsVision: id.isMultiple(of: 2),
            supportsTools: !id.isMultiple(of: 3),
            supportsThinking: id.isMultiple(of: 5),
            contextWindow: id.isMultiple(of: 2) ? 128_000 : 32_000,
            isEnabled: .constant(id.isMultiple(of: 7)))
    }
}

private struct CountedSettingsRow: View {
    let id: Int
    let counter: SettingsRowCounter

    var body: some View {
        let _ = counter.realized.insert(id)
        HStack {
            Image(systemName: "cube")
            Text(verbatim: "Synthetic model \(id)")
            Spacer()
            Toggle("In Model Pool", isOn: .constant(false)).toggleStyle(.switch)
        }
        .frame(height: 60)
    }
}
