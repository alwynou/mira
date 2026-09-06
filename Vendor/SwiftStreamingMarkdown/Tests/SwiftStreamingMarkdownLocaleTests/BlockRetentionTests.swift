#if DEBUG && canImport(AppKit)
import AppKit
import SwiftUI
import Testing
@testable import SwiftStreamingMarkdown

@MainActor
@Suite("Eager Markdown block retention")
struct BlockRetentionTests {
  private func blocks(_ count: Int, suffix: String = "") -> [MarkdownRenderable] {
    (0..<count).map { index in
      .paragraph(id: "paragraph-\(index)", content: NSMutableAttributedString(string:
        "Paragraph \(index). " + String(repeating: "Wrapping text remains selectable. ", count: 5) + (index == count - 1 ? suffix : "")))
    }
  }

  private func paragraphs(in view: NSView) -> [ParagraphNSView] {
    if let paragraph = view as? ParagraphNSView { return [paragraph] }
    return view.subviews.flatMap { paragraphs(in: $0) }
  }

  private func layout(_ host: NSHostingView<BlockView>, width: CGFloat = 480) -> [ParagraphNSView] {
    host.frame = CGRect(x: 0, y: 0, width: width, height: 4_000)
    host.layoutSubtreeIfNeeded()
    _ = host.fittingSize
    host.layoutSubtreeIfNeeded()
    return paragraphs(in: host)
  }

  @Test("appending blocks preserves native prefix views and selection")
  func appendRetainsPrefix() throws {
    let host = NSHostingView(rootView: BlockView(renderables: blocks(8)))
    let before = layout(host)
    #expect(before.count == 8)
    let selected = try #require(before.first)
    selected.setSelectedRange(NSRange(location: 0, length: 9))
    let identities = Set(before.map(ObjectIdentifier.init))

    host.rootView = BlockView(renderables: blocks(9))
    let appended = layout(host)
    #expect(appended.count == 9)
    #expect(identities.isSubset(of: Set(appended.map(ObjectIdentifier.init))))
    #expect(selected.selectedRange() == NSRange(location: 0, length: 9))

    host.rootView = BlockView(renderables: blocks(9, suffix: "The live tail grows."))
    let updated = layout(host)
    #expect(Set(appended.map(ObjectIdentifier.init)) == Set(updated.map(ObjectIdentifier.init)))
    #expect(updated.contains { $0.string.hasSuffix("The live tail grows.") })
  }

  @Test("replacement and resizing do not retain stale blocks or zero heights")
  func replacementAndResize() {
    let host = NSHostingView(rootView: BlockView(renderables: blocks(17)))
    let wide = layout(host, width: 640)
    #expect(wide.count == 17)
    let narrow = layout(host, width: 280)
    #expect(narrow.count == 17)
    #expect(narrow.allSatisfy { $0.frame.height > 0 && $0.frame.height.isFinite })

    host.rootView = BlockView(renderables: blocks(2, suffix: "Replacement content."))
    let replaced = layout(host, width: 280)
    #expect(replaced.count == 2)
    #expect(replaced.contains { $0.string.hasSuffix("Replacement content.") })
  }

  @Test("environment updates reach native paragraphs inside equal content wrappers")
  func environmentCrossesEqualityBoundary() throws {
    let host = NSHostingView(rootView: EnvironmentFixture(locale: Locale(identifier: "en"), animatesUpdates: true))
    host.frame = CGRect(x: 0, y: 0, width: 480, height: 200)
    host.layoutSubtreeIfNeeded()
    _ = host.fittingSize
    host.layoutSubtreeIfNeeded()
    let paragraph = try #require(paragraphs(in: host).first)
    let initialMenu = try #require(paragraph.textContextMenu)

    host.rootView = EnvironmentFixture(locale: Locale(identifier: "zh-Hans"), animatesUpdates: true)
    host.layoutSubtreeIfNeeded()
    _ = host.fittingSize
    host.layoutSubtreeIfNeeded()
    #expect(paragraphs(in: host).first === paragraph)
    #expect(paragraph.textContextMenu != initialMenu)
    #expect(paragraph.textContextMenu == MarkdownRenderConfig.default.resolvedTextContextMenu(locale: Locale(identifier: "zh-Hans")))

    let manager = try #require(paragraph.layoutManager as? StreamingFadeLayoutManager)
    manager.fade.append(previous: "", current: paragraph.string, enabled: true, at: 1)
    #expect(!manager.fade.batches.isEmpty)
    host.rootView = EnvironmentFixture(locale: Locale(identifier: "zh-Hans"), animatesUpdates: false)
    host.layoutSubtreeIfNeeded()
    _ = host.fittingSize
    host.layoutSubtreeIfNeeded()
    #expect(manager.fade.batches.isEmpty)
  }
}

private struct EnvironmentFixture: View {
  let locale: Locale
  let animatesUpdates: Bool
  var body: some View {
    EqualParagraph().equatable()
      .environment(\.locale, locale)
      .environment(\.markdownAnimatesTextUpdates, animatesUpdates)
  }
}

private struct EqualParagraph: View, Equatable {
  var body: some View {
    ParagraphView(contents: NSMutableAttributedString(string: "Stable paragraph with a live environment."))
  }
}
#endif
