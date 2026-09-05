import Foundation
import Testing
@testable import SwiftStreamingMarkdown

@Suite("SwiftStreamingMarkdown locale helpers")
struct RendererLocalizationTests {
  @Test("code labels use the requested locale")
  func codeLabelsUseRequestedLocale() {
    let chinese = Locale(identifier: "zh-CN")
    #expect(String.codeCopyLabel(locale: chinese) == "复制") // i18n-fixture: Expected Simplified Chinese rendering.
    #expect(String.codeCopiedLabel(locale: chinese) == "已复制") // i18n-fixture: Expected Simplified Chinese rendering.
    #expect(String.codeCopyLabel(locale: Locale(identifier: "en-US")) == "Copy")
    #expect(String.codeCopyLabel(locale: Locale(identifier: "fr-FR")) == "Copy")
    #expect(String.codeCopyLabel(locale: Locale(identifier: "zh-Hant-TW")) == "Copy")
  }

  @Test("table and list labels use the requested locale")
  func tableAndListLabelsUseRequestedLocale() {
    let chinese = Locale(identifier: "zh-CN")
    #expect(String.itemPositionInTable(rowIndex: 2, totalRow: 4, columnIndex: 1, totalColumn: 3, locale: chinese) == "第 2 行(共 4 行)，第 1 列(共 3 列)") // i18n-fixture: Expected Simplified Chinese rendering.
    #expect(String.markdownListItem(length: 3, index: 2, item: "内容", locale: chinese) == "列表共 3 项，第 2 项：内容") // i18n-fixture: Expected Simplified Chinese rendering.
    #expect(String.taskListItemChecked(locale: chinese) == "已选中") // i18n-fixture: Expected Simplified Chinese rendering.
    #expect(String.taskListItemUnchecked(locale: chinese) == "未选中") // i18n-fixture: Expected Simplified Chinese rendering.
  }

  @MainActor @Test("text selection menu follows the requested locale")
  func textSelectionMenuUsesRequestedLocale() {
    let config = MarkdownRenderConfig.default
    #expect(config.resolvedTextContextMenu(locale: Locale(identifier: "en"))?.menuGroups.first?.items.first?.title == "Select more text")
    #expect(config.resolvedTextContextMenu(locale: Locale(identifier: "zh-CN"))?.menuGroups.first?.items.first?.title == String.selectMoreTextLabel(locale: Locale(identifier: "zh-CN")))
    #expect(String.selectMoreTextLabel(locale: Locale(identifier: "zh-CN")) != "Select more text")
  }

}
