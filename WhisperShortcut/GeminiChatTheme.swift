import SwiftUI

/// Fixed appearance for the Open Gemini chat window (dark, no theme switching).
/// Dark palette closely matching Claude's UI: near-black surfaces with warm undertones.
enum GeminiChatTheme {
  /// Main content area background (message list). Dark neutral gray, similar to ChatGPT.
  static let windowBackground = Color(red: 33/255, green: 33/255, blue: 33/255)    // #212121
  /// Input bar, command overlay. Slightly elevated surface.
  static let controlBackground = Color(red: 44/255, green: 44/255, blue: 44/255)   // #2C2C2C
  /// User message bubble background. Slightly elevated from window background.
  static let userBubbleBackground = Color(red: 45/255, green: 45/255, blue: 45/255) // #2D2D2D
  /// Primary text (messages, headers). Soft white for comfortable reading.
  static let primaryText = Color(red: 236/255, green: 236/255, blue: 236/255)      // #ECECEC
  /// Secondary text (buttons, captions).
  static var secondaryText: Color { primaryText.opacity(0.65) }
  /// Border opacity (e.g. input stroke). Subtle.
  static let borderOpacity: Double = 0.18
}
