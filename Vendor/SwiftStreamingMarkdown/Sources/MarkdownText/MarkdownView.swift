//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI
import Equatable

/// This is a view that is able to both parse and render markdown with default configuration.
/// Use this view instead of `DocumentView` if you don't want to perform the parsing yourself.
@Equatable
public struct MarkdownView: View {

  private let text: String
  private let config: MarkdownRenderConfig
  private let animatesTextUpdates: Bool
  @StateObject var controller: MarkdownViewController

  /// Create a `MarkdownView`.
  /// - Parameters:
  ///   - text: The raw Markdown source to parse and render.
  ///   - config: Render configuration. Defaults to `.default`.
  ///   - listener: Optional listener that receives render and interaction events.
  ///   - animatesTextUpdates: Fade appended macOS paragraph text after the initial snapshot.
  ///     Switching this off immediately finishes any active text fades.
  public init(
    text: String,
    config: MarkdownRenderConfig = .default,
    listener: MarkdownListener? = nil,
    animatesTextUpdates: Bool = false
  ) {
    self.text = text
    self.animatesTextUpdates = animatesTextUpdates
    self.config = config
    _controller = StateObject(wrappedValue: MarkdownViewController(config: config, listener: listener))
  }

  public var body: some View {
    Group {
      if let renderable = controller.renderable {
        DocumentView(renderableDocument: renderable, config: config, listener: controller.listener)
      } else {
        DocumentView(renderableDocument: .empty, config: config, listener: controller.listener)
      }
    }
    .environment(\.markdownAnimatesTextUpdates, animatesTextUpdates && controller.hasParsedUpdate)
    .task(id: text) {
      await controller.parse(text: text)
    }
  }
}

@MainActor
final class MarkdownViewController: ObservableObject {

  @Published var renderable: RenderableDocument?
  @Published private(set) var hasParsedUpdate = false

  private let config: MarkdownRenderConfig
  private let parser = MarkdownParserImpl()

  let listener: MarkdownListener?

  init(config: MarkdownRenderConfig = .default, listener: MarkdownListener? = nil) {
    self.config = config
    self.listener = listener
  }

  func parse(text: String) async {
    guard !Task.isCancelled else { return }
    let renderable = await parser.parse(text: text, config: config)
    guard !Task.isCancelled else { return }
    self.hasParsedUpdate = self.renderable != nil
    self.renderable = renderable
  }
}

extension EnvironmentValues {
  @Entry var markdownAnimatesTextUpdates = false
}
