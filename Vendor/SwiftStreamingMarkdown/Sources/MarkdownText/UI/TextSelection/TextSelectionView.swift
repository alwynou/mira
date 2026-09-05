//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import SwiftUI

/// A modal that presents the full document as selectable, uneditable text so
/// the user can select more than the tapped block. Presented by `DocumentView`
/// when the built-in "Select more text" edit-menu action is invoked.
struct TextSelectionView: View {
  @Environment(\.locale) private var locale
  let text: String
  let backgroundColor: Color
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      TextSelectionHeader(title: String.selectMoreTextLabel(locale: locale), onDismiss: onDismiss)
      SelectableTextView(text: text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
    }
    .background(backgroundColor.ignoresSafeArea())
    #if os(macOS)
    .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 680)
    #endif
  }
}

private struct TextSelectionHeader: View {
  let title: String
  let onDismiss: () -> Void

  @Environment(\.markdownConfig) var markdownConfig: MarkdownRenderConfig
  @Environment(\.locale) private var locale

  var body: some View {
    ZStack {
      Text(title)
        .font(Font(markdownConfig.headingStyle.h3Font.bold ?? markdownConfig.headingStyle.h3Font.normal))
        .foregroundStyle(markdownConfig.headingStyle.textColor)
        .accessibilityAddTraits(.isHeader)

      HStack {
        Spacer()
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .foregroundStyle(markdownConfig.headingStyle.textColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String.textSelectionCloseLabel(locale: locale)))
      }
    }
    .padding(.vertical, 18)
    .padding(.horizontal, 24)
    .overlay(
      Rectangle()
        .frame(height: 1)
        .foregroundStyle(markdownConfig.thematicBreakColor),
      alignment: .bottom
    )
  }
}

#if DEBUG
#Preview {
  TextSelectionView(
    text: "The quick brown fox jumps over the lazy dog.\n\nSecond paragraph for selection.",
    backgroundColor: Color.Theme.Background.Page.Chat.Flat,
    onDismiss: {}
  )
}
#endif
