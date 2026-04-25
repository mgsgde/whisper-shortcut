import SwiftUI

/// Fixed appearance for the chat window (dark, no theme switching).
/// Dark palette closely matching Claude's UI: near-black surfaces with warm undertones.
enum ChatTheme {
  /// Main content area background (message list). Dark, matching ChatGPT.
  static let windowBackground = Color(red: 23/255, green: 23/255, blue: 23/255)    // #171717
  /// Input bar, command overlay. Slightly elevated surface.
  static let controlBackground = Color(red: 35/255, green: 35/255, blue: 35/255)   // #232323
  /// User message bubble background. Slightly elevated from window background.
  static let userBubbleBackground = Color(red: 38/255, green: 38/255, blue: 38/255) // #262626
  /// Primary text (messages, headers). Soft white for comfortable reading.
  static let primaryText = Color(red: 236/255, green: 236/255, blue: 236/255)      // #ECECEC
  /// Secondary text (buttons, captions).
  static var secondaryText: Color { primaryText.opacity(0.65) }
  /// Border opacity (e.g. input stroke). Subtle.
  static let borderOpacity: Double = 0.18
}
