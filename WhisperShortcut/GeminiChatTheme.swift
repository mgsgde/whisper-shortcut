import SwiftUI

/// Fixed appearance for the Open Gemini chat window (dark, no theme switching).
/// Dark palette closely matching Claude's UI: near-black surfaces with warm undertones.
enum GeminiChatTheme {
  /// Main content area background (message list). Very dark, matching Claude's chat background.
  static let windowBackground = Color(red: 33/255, green: 32/255, blue: 30/255)    // #21201E
  /// Input bar, command overlay. Slightly elevated surface.
  static let controlBackground = Color(red: 44/255, green: 42/255, blue: 40/255)   // #2C2A28
  /// User message bubble background. Very dark, almost same as chat background (Claude-style).
  static let userBubbleBackground = Color(red: 26/255, green: 25/255, blue: 23/255) // #1A1917
  /// Primary text (messages, headers). Warm off-white / cream.
  static let primaryText = Color(red: 236/255, green: 233/255, blue: 228/255)      // #ECE9E4
  /// Secondary text (buttons, captions).
  static var secondaryText: Color { primaryText.opacity(0.65) }
  /// Border opacity (e.g. input stroke). Subtle.
  static let borderOpacity: Double = 0.18
}
