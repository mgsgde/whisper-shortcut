import SwiftUI
import AppKit

/// Prose typeface family for the chat. All options are system fonts (no bundled
/// files), so flipping `ChatTheme.bodyFontDesign` A/B-tests them app-wide instantly.
enum ChatFontDesign {
  case sans     // San Francisco (SF Pro) — the macOS system font
  case serif    // New York (Apple's optically-sized system serif)
  case rounded  // SF Pro Rounded

  var swiftUI: Font.Design {
    switch self {
    case .sans: return .default
    case .serif: return .serif
    case .rounded: return .rounded
    }
  }
  var appKit: NSFontDescriptor.SystemDesign {
    switch self {
    case .sans: return .default
    case .serif: return .serif
    case .rounded: return .rounded
    }
  }
}

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
  static let bodyFontSize: CGFloat = 16
  /// Line spacing paired with `bodyFontSize` to hold a ~1.5× line height.
  static let bodyLineSpacing: CGFloat = 7
  /// A touch of letter spacing on body prose. On dark backgrounds light text tends to
  /// bloom/blur ("halation"); a hair of tracking keeps glyphs crisp. Keep it tiny.
  static let bodyTracking: CGFloat = 0.2
  /// Regular body weight for plain prose. Kept at `.regular` (the lighter look preferred
  /// over a heavier nudge); bold/headings set their own weights.
  static let bodyRegularNSWeight = NSFont.Weight.regular

  /// A/B switch for the prose typeface. `.sans` = San Francisco (default); flip to
  /// `.serif` (New York) or `.rounded` (SF Pro Rounded) to compare legibility in-app.
  static let bodyFontDesign: ChatFontDesign = .sans

  /// SwiftUI prose font honoring `bodyFontDesign`. Used on the streaming-text and
  /// user-bubble paths.
  static func bodyFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: bodyFontDesign.swiftUI)
  }

  /// AppKit twin of `bodyFont` for the selectable NSTextView prose path. Applies the
  /// chosen design, then layers weight and any bold/italic symbolic traits on top.
  static func bodyNSFont(size: CGFloat, weight: NSFont.Weight = .regular,
                         traits: NSFontDescriptor.SymbolicTraits = []) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    var descriptor = base.fontDescriptor
    if let designed = descriptor.withDesign(bodyFontDesign.appKit) { descriptor = designed }
    if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) }
    return NSFont(descriptor: descriptor, size: size) ?? base
  }
  /// Secondary text (buttons, captions).
  static var secondaryText: Color { primaryText.opacity(0.65) }
  /// Border opacity (e.g. input stroke). Subtle.
  static let borderOpacity: Double = 0.18

  // MARK: - AppKit bridges
  // The chat window is a fixed dark theme, so AppKit views inside it must not use the
  // system's appearance-dependent `labelColor`/`secondaryLabelColor` — under a light
  // system appearance those resolve to near-black on the dark composer.
  static var primaryNSText: NSColor { NSColor(primaryText) }
  static var secondaryNSText: NSColor { NSColor(secondaryText) }
}
