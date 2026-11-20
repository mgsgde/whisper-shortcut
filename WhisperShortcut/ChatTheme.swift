import SwiftUI
import AppKit

/// Prose typeface family for the chat. All options are system fonts (no bundled files).
/// The user picks one in Settings → Chat → Appearance; `ChatTheme.bodyFontDesign` reads it.
enum ChatFontDesign: String, CaseIterable {
  case sans     // San Francisco (SF Pro) — the macOS system font
  case serif    // New York (Apple's optically-sized system serif)
  case rounded  // SF Pro Rounded

  /// Label shown in the Settings picker.
  var displayName: String {
    switch self {
    case .sans: return String(localized: "Sans")
    case .serif: return String(localized: "Serif")
    case .rounded: return String(localized: "Rounded")
    }
  }

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
/// Warm dark palette modeled on Claude's dark mode (Magnus, 2026-11-20: the navy /
/// near-black + pure-white look read "zu aggressiv, zu grell"). Surfaces are warm
/// charcoals a few steps apart, text is an off-white with a paper tint, so nothing glares.
/// Like Claude, the system accent (blue) stays for toggles and links; the terracotta
/// `accent` is used only for the send button.
enum ChatTheme {
  /// Main content area background (message list) — Claude's dark canvas.
  static let windowBackground = Color(red: 38/255, green: 38/255, blue: 36/255)    // #262624
  /// Composer, input bar, command overlay. One step lighter than the canvas.
  static let controlBackground = Color(red: 48/255, green: 48/255, blue: 46/255)   // #30302E
  /// Left sidebar — one step darker than the canvas, not near-black.
  static let sidebarBackground = Color(red: 31/255, green: 30/255, blue: 29/255)   // #1F1E1D
  /// Top navigation/status bar — matches the sidebar.
  static let topBarBackground = sidebarBackground
  /// User message bubble — a darker well inside the canvas, like Claude's user turn.
  static let userBubbleBackground = Color(red: 20/255, green: 20/255, blue: 19/255) // #141413
  /// Primary text (messages, headers). Warm off-white, never pure white.
  static let primaryText = Color(red: 245/255, green: 244/255, blue: 237/255)      // #F5F4ED
  /// Send button fill — Claude's terracotta. Deliberately not the app-wide accent.
  static let sendAccent = Color(red: 217/255, green: 119/255, blue: 87/255)        // #D97757
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

  /// The prose typeface the user picked in Settings → Chat → Appearance. Read straight from
  /// `UserDefaults` (not cached) so a change applies on the next render; the default is `.sans`,
  /// which is what the chat has always used.
  static var bodyFontDesign: ChatFontDesign {
    UserDefaults.standard.string(forKey: UserDefaultsKeys.chatFontDesign)
      .flatMap(ChatFontDesign.init(rawValue:)) ?? SettingsDefaults.chatFontDesign
  }

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

/// Settings window palette, modeled on Claude's settings (Magnus, 2026-11-20). Unlike the chat,
/// Settings follows the system appearance, so every color has a light and a dark value: dark is
/// Claude's warm charcoal, light its paper white. Toggles and links keep the system accent.
enum SettingsTheme {
  private static func dynamic(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
  }
  private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
  }

  /// Detail pane.
  static let canvas = dynamic(light: rgb(250, 249, 245), dark: rgb(38, 38, 36))     // #FAF9F5 / #262624
  /// Sidebar column, one step off the canvas.
  static let sidebar = dynamic(light: rgb(240, 238, 230), dark: rgb(31, 30, 29))    // #F0EEE6 / #1F1E1D
  /// Selected sidebar row — a quiet fill, never a solid accent block.
  static let selection = dynamic(
    light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.09))
  /// Hovered sidebar row.
  static let hover = dynamic(
    light: NSColor.black.withAlphaComponent(0.04), dark: NSColor.white.withAlphaComponent(0.05))
}
