import SwiftUI

/// Fixed appearance for the Open Gemini chat window (dark, no theme switching).
/// Readability-optimized colors: softer dark background (Claude-like), off-white text (WCAG AAA).
enum GeminiChatTheme {
  /// Main content area background (message list, sheet). Softer than pure black for less stark contrast.
  static let windowBackground = Color(red: 28/255, green: 28/255, blue: 30/255)   // #1c1c1e
  /// Input bar, command overlay, buttons. Slightly lighter so input area is distinct.
  static let controlBackground = Color(red: 45/255, green: 45/255, blue: 48/255)   // #2d2d30
  /// User message bubble background (distinct from selection blue; slightly elevated surface).
  static let userBubbleBackground = Color(red: 48/255, green: 48/255, blue: 52/255)   // #303034
  /// Primary text (messages, headers).
  static let primaryText = Color(red: 232/255, green: 232/255, blue: 232/255)      // #E8E8E8
  /// Secondary text (buttons, captions).
  static var secondaryText: Color { primaryText.opacity(0.75) }
  /// Border opacity (e.g. input stroke). Higher so input field has a visible border.
  static let borderOpacity: Double = 0.28
}
