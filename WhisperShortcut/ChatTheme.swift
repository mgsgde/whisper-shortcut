import SwiftUI

/// Fixed appearance for the chat window (dark, no theme switching).
/// Dark palette with a subtle navy undertone, inspired by deep-blue editor
/// themes (GitHub Dark, Cursor/VSCode navy): blue channel leads each surface
/// so the panes read as dark-blue rather than neutral grey.
enum ChatTheme {
  /// Main content area background (message list). Slightly elevated above the
  /// sidebar so the conversation pane reads as the focused surface, like
  /// macOS native (Mail, System Settings) and editors (Cursor, VSCode).
  static let windowBackground = Color(red: 12/255, green: 17/255, blue: 23/255)    // #0C1117
  /// Input bar, command overlay. Slightly elevated surface.
  static let controlBackground = Color(red: 22/255, green: 28/255, blue: 38/255)   // #161C26
  /// Left sidebar background — near-black (Cursor-style), so the navy main pane
  /// reads as a distinct blue surface against it.
  static let sidebarBackground = Color(red: 2/255, green: 4/255, blue: 8/255)      // #020408
  /// Top navigation/status bar — matches the sidebar's near-black so the chrome
  /// frames the navy conversation pane on all sides.
  static let topBarBackground = sidebarBackground
  /// User message bubble background — matches the conversation pane / composer
  /// (#0C1117) so "what I typed" reads the same as "where I type"; a 1px stroke
  /// (applied at the call site) keeps the bubble delineated.
  static let userBubbleBackground = windowBackground
  /// Primary text (messages, headers). Soft white for comfortable reading.
  static let primaryText = Color(red: 236/255, green: 236/255, blue: 236/255)      // #ECECEC
  /// Body prose font size — single source of truth for chat messages (prose, bullets,
  /// user bubble) and the base for relative heading sizes.
  static let bodyFontSize: CGFloat = 15
  /// Line spacing paired with `bodyFontSize` to hold a ~1.5× line height.
  static let bodyLineSpacing: CGFloat = 7
  /// Secondary text (buttons, captions).
  static var secondaryText: Color { primaryText.opacity(0.65) }
  /// Border opacity (e.g. input stroke). Subtle.
  static let borderOpacity: Double = 0.18
}
