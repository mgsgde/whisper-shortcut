import SwiftUI

/// Fixed appearance for the Open Gemini chat window (dark, no theme switching).
/// Readability-optimized colors: near-black background, off-white text (WCAG AAA).
enum GeminiChatTheme {
  /// Main content area background (message list, sheet).
  static let windowBackground = Color(red: 18/255, green: 18/255, blue: 18/255)   // #121212
  /// Input bar, command overlay, buttons.
  static let controlBackground = Color(red: 30/255, green: 30/255, blue: 30/255)   // #1E1E1E
  /// Primary text (messages, headers).
  static let primaryText = Color(red: 232/255, green: 232/255, blue: 232/255)      // #E8E8E8
  /// Secondary text (buttons, captions).
  static var secondaryText: Color { primaryText.opacity(0.75) }
  /// Border opacity (e.g. input stroke).
  static let borderOpacity: Double = 0.15
}
