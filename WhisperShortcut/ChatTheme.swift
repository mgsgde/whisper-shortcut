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
/// Values are copied 1:1 from the Claude desktop app's design-system tokens (`--cds-*`, dark
/// mode, read from Claude.app's bundle on 2026-11-20 and checked against screen pixels):
/// neutral greys, translucent white text, blue accent. Magnus, 2026-11-20: the navy +
/// pure-white look was "zu aggressiv, zu grell"; Claude's reads calm.
enum ChatTheme {
  /// Conversation pane — `--cds-surface-1`.
  static let windowBackground = Color(red: 25/255, green: 25/255, blue: 25/255)    // #191919
  /// Composer, input bar, command overlay — `--cds-surface-popover` (measured on the composer).
  static let controlBackground = Color(red: 48/255, green: 48/255, blue: 48/255)   // #303030
  /// Left sidebar — `--cds-fizzy-lake-color-sidebar`.
  static let sidebarBackground = Color(red: 31/255, green: 31/255, blue: 31/255)   // #1F1F1F
  /// Top bar — `--cds-gray-830`, the slightly raised strip above the conversation.
  static let topBarBackground = Color(red: 26/255, green: 26/255, blue: 26/255)    // #1A1A1A
  /// User message bubble — `--cds-fill-secondary-layer` (#ffffff13) over surface-1.
  static let userBubbleBackground = Color(red: 42/255, green: 42/255, blue: 42/255) // #2A2A2A
  /// Primary text — `--cds-text-primary` (#ffffffed).
  static let primaryText = Color.white.opacity(0.93)
  /// Selected sidebar row — `--cds-fill-ghost-selected` (#ffffff26).
  static let selectedRowFill = Color.white.opacity(0.15)
  /// Hovered row — `--cds-fill-ghost-hover` (#ffffff13).
  static let hoverRowFill = Color.white.opacity(0.075)
  /// Send button — Claude's `--accent-brand` terracotta (hsl 15 63.1% 59.6%).
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
  static var secondaryText: Color { Color.white.opacity(0.57) }  // --cds-text-secondary #ffffff91
  /// Border opacity (e.g. input stroke). Subtle.
  static let borderOpacity: Double = 0.12  // --cds-border-line #ffffff1f

  // MARK: - AppKit bridges
  // The chat window is a fixed dark theme, so AppKit views inside it must not use the
  // system's appearance-dependent `labelColor`/`secondaryLabelColor` — under a light
  // system appearance those resolve to near-black on the dark composer.
  static var primaryNSText: NSColor { NSColor(primaryText) }
  static var secondaryNSText: NSColor { NSColor(secondaryText) }
}

/// Settings window palette — Claude desktop's `--cds-*` tokens for light and dark (Magnus,
/// 2026-11-20). Unlike the chat, Settings follows the system appearance. Toggles and links use
/// the AccentColor asset, which carries Claude's `--cds-blue-450`.
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
  static let canvas = dynamic(light: rgb(255, 255, 255), dark: rgb(25, 25, 25))     // surface-1 #FFFFFF / #191919
  /// Sidebar column, one step off the canvas.
  static let sidebar = dynamic(light: rgb(250, 250, 250), dark: rgb(31, 31, 31))    // sidebar #FAFAFA / #1F1F1F
  /// Selected sidebar row — a quiet fill, never a solid accent block.
  static let selection = dynamic(
    light: NSColor.black.withAlphaComponent(0.10), dark: NSColor.white.withAlphaComponent(0.15))  // ghost-selected
  /// Hovered sidebar row.
  static let hover = dynamic(
    light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.075))  // ghost-hover
}
