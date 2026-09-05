//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown

extension String {

  private static func localeCandidates(for locale: Locale) -> [String] {
    let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
    let languageCode = locale.language.languageCode?.identifier
    switch languageCode {
    case "en":
      return [identifier, "en"]
    case "zh":
      guard locale.language.script?.identifier != "Hant" else { return [] }
      return [identifier, "zh-Hans"]
    default:
      return []
    }
  }

  private static func localizedBundle(for locale: Locale?) -> Bundle {
    guard let locale else { return .module }
    for candidate in localeCandidates(for: locale) + ["en"] {
      if let url = Bundle.module.url(forResource: candidate, withExtension: "lproj"),
         let bundle = Bundle(url: url) {
        return bundle
      }
    }
    return .module
  }

  private static func localized(_ key: String, fallback: String, locale: Locale? = nil) -> String {
    return localizedBundle(for: locale).localizedString(forKey: key, value: fallback, table: "Localizable")
  }

  public func markdownToPlainText(removeHeading: Bool = false, coder: CitationCoder = .default) async -> String {
    let markdownParser = MarkdownParserImpl()
    let document = await markdownParser.parse(text: self)
    return document.extractPlainText(removeHeading: removeHeading, coder: coder)
  }

  static func itemPositionInTable(rowIndex: Int, totalRow: Int, columnIndex: Int, totalColumn: Int, locale: Locale? = nil) -> String {
    let format = localized(
      "a11y_item_position_in_table",
      fallback: "Row %d of %d, Column %d of %d",
      locale: locale
    )
    return String(format: format, locale: locale, arguments: [rowIndex, totalRow, columnIndex, totalColumn])
  }

  static func openCitation(citationLabel: String, locale: Locale? = nil) -> String {
    let format = localized("a11y_open_citation", fallback: "Open %@, link", locale: locale)
    return String(format: format, locale: locale, arguments: [citationLabel])
  }

  static func markdownListItem(length: Int, index: Int, item: String, locale: Locale? = nil) -> String {
    let format = localized(
      "markdown_list_item",
      fallback: "List with %1$d items, item %2$d: %3$@",
      locale: locale
    )
    return String(format: format, locale: locale, arguments: [length, index, item])
  }

  static func codeCopyLabel(locale: Locale? = nil) -> String {
    localized("code_block_copy", fallback: "Copy", locale: locale)
  }

  static func taskListItemChecked(locale: Locale? = nil) -> String {
    localized("a11y_task_list_item_checked", fallback: "checked", locale: locale)
  }

  static var taskListItemChecked: String { taskListItemChecked(locale: nil) }

  static func taskListItemUnchecked(locale: Locale? = nil) -> String {
    localized("a11y_task_list_item_unchecked", fallback: "unchecked", locale: locale)
  }

  static var taskListItemUnchecked: String { taskListItemUnchecked(locale: nil) }

  static var codeCopyLabel: String { codeCopyLabel(locale: nil) }

  static func codeCopiedLabel(locale: Locale? = nil) -> String {
    localized("code_block_copied", fallback: "Copied", locale: locale)
  }

  static var codeCopiedLabel: String { codeCopiedLabel(locale: nil) }

  static func selectMoreTextLabel(locale: Locale? = nil) -> String {
    localized("select_more_text", fallback: "Select more text", locale: locale)
  }

  static var selectMoreTextLabel: String { selectMoreTextLabel(locale: nil) }

  static func textSelectionCloseLabel(locale: Locale? = nil) -> String {
    localized("a11y_text_selection_close", fallback: "Close", locale: locale)
  }

  static var textSelectionCloseLabel: String { textSelectionCloseLabel(locale: nil) }

  static let imageLabel = NSLocalizedString(
    "a11y_image",
    bundle: .module,
    value: "Image",
    comment: "Accessibility label for a block image that has no alt text"
  )

  static let imageViewerCloseLabel = NSLocalizedString(
    "a11y_image_viewer_close",
    bundle: .module,
    value: "Close",
    comment: "Accessibility label for the button that dismisses the fullscreen image viewer"
  )

}

extension Markdown.Document {
  func extractPlainText(removeHeading: Bool, coder: CitationCoder = .default) -> String {
    var result = ""

    for child in children {
      result += child.extractPlainText(removeHeading: removeHeading, coder: coder)
      result += "\n\n"
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension Markup {
  /// Recursively extracts plain text from any markdown element
  func extractPlainText(removeHeading: Bool, coder: CitationCoder = .default) -> String {
    // Handle specific markup types
    switch self {
    case let text as Markdown.Text:
      return text.string

    case let heading as Heading:
      return removeHeading ? "" : heading.plainText

    case let paragraph as Paragraph:
      // Extract text from paragraph children to handle attachment citations
      return paragraph.children.map {
        $0.extractPlainText(removeHeading: removeHeading, coder: coder)
      }.joined()

    case let codeBlock as CodeBlock:
      return codeBlock.code

    case let inlineCode as Markdown.InlineCode:
      return inlineCode.code

    case let link as Markdown.Link:
      // Handle attachment citations by extracting title from URL parameters
      if let destination = link.destination,
         let url = URL.fromMixedEncodingString(destination),
         coder.isCitation(linkText: link.plainText, url: url),
         let attachmentData = coder.decode(linkDestination: destination) {
        return attachmentData.title
      }

      // For regular links, extract the link text content, not the URL
      var linkText = ""
      for child in link.children {
        linkText += child.extractPlainText(removeHeading: removeHeading, coder: coder)
      }
      return linkText.isEmpty ? (link.destination ?? "") : linkText

    case let emphasis as Markdown.Emphasis:
      var text = ""
      for child in emphasis.children {
        text += child.extractPlainText(removeHeading: removeHeading, coder: coder)
      }
      return text

    case let strong as Markdown.Strong:
      var text = ""
      for child in strong.children {
        text += child.extractPlainText(removeHeading: removeHeading, coder: coder)
      }
      return text

    case let strikethrough as Markdown.Strikethrough:
      var text = ""
      for child in strikethrough.children {
        text += child.extractPlainText(removeHeading: removeHeading, coder: coder)
      }
      return text

    case let listItem as ListItem:
      var text = ""
      for child in listItem.children {
        text += child.extractPlainText(removeHeading: removeHeading, coder: coder)
      }
      return text

    case let orderedList as OrderedList:
      var text = ""
      for (index, child) in orderedList.children.enumerated() {
        if let listItem = child as? ListItem {
          text += "\(index + 1). \(listItem.extractPlainText(removeHeading: removeHeading, coder: coder))\n"
        }
      }
      return text

    case let unorderedList as UnorderedList:
      var text = ""
      for child in unorderedList.children {
        if let listItem = child as? ListItem {
          text += "• \(listItem.extractPlainText(removeHeading: removeHeading, coder: coder))\n"
        }
      }
      return text

    case let blockQuote as BlockQuote:
      var text = ""
      for child in blockQuote.children {
        text += child.extractPlainText(removeHeading: removeHeading, coder: coder)
      }
      return text

    case let table as Markdown.Table:
      var text = ""
      // Extract table headers
      for cell in table.head.children {
        if let tableCell = cell as? Markdown.Table.Cell {
          text += tableCell.extractPlainText(removeHeading: removeHeading, coder: coder) + "\t"
        }
      }
      text += "\n"

      // Extract table rows
      for row in table.body.children {
        if let tableRow = row as? Markdown.Table.Row {
          for cell in tableRow.children {
            if let tableCell = cell as? Markdown.Table.Cell {
              text += tableCell.extractPlainText(removeHeading: removeHeading, coder: coder) + "\t"
            }
          }
          text += "\n"
        }
      }
      return text

    case let tableCell as Markdown.Table.Cell:
      var text = ""
      for child in tableCell.children {
        text += child.extractPlainText(removeHeading: removeHeading, coder: coder)
      }
      return text

    case is ThematicBreak:
      return "---"

    case is Markdown.LineBreak:
      return "\n"

    case is Markdown.SoftBreak:
      return " "

    default:
      // For any other markup type, recursively process children
      var text = ""
      for child in children {
        text += child.extractPlainText(removeHeading: removeHeading, coder: coder)
      }
      return text
    }
  }
}
