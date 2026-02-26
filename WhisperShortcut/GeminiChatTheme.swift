import SwiftUI
import AppKit

/// Theme for the Open Gemini chat window: light (black on white) or dark (white on black).
/// Uses readability-optimized colors (off-white / near-black) for comfort and WCAG AAA contrast.
enum GeminiChatTheme: String, CaseIterable {
  case light
  case dark

  /// Opposite theme for toggling (e.g. /theme command).
  var opposite: GeminiChatTheme {
    switch self {
    case .light: return .dark
    case .dark: return .light
    }
  }

  // MARK: - Readability-optimized colors (sRGB)

  /// Light theme: off-white background, near-black text (reduces glare, WCAG AAA).
  private static let lightWindowBackground = Color(red: 250/255, green: 250/255, blue: 250/255)   // #FAFAFA
  private static let lightControlBackground = Color(red: 245/255, green: 245/255, blue: 245/255) // #F5F5F5
  private static let lightPrimaryText = Color(red: 26/255, green: 26/255, blue: 26/255)          // #1A1A1A

  /// Dark theme: near-black background, off-white text (reduces eye strain, WCAG AAA).
  private static let darkWindowBackground = Color(red: 18/255, green: 18/255, blue: 18/255)       // #121212
  private static let darkControlBackground = Color(red: 30/255, green: 30/255, blue: 30/255)      // #1E1E1E
  private static let darkPrimaryText = Color(red: 232/255, green: 232/255, blue: 232/255)          // #E8E8E8

  /// Main content area background (message list, sheet).
  var windowBackground: Color {
    switch self {
    case .light: return Self.lightWindowBackground
    case .dark: return Self.darkWindowBackground
    }
  }

  /// Input bar, assistant bubbles, command overlay, buttons.
  var controlBackground: Color {
    switch self {
    case .light: return Self.lightControlBackground
    case .dark: return Self.darkControlBackground
    }
  }

  /// Primary text (assistant replies, headers when themed).
  var primaryText: Color {
    switch self {
    case .light: return Self.lightPrimaryText
    case .dark: return Self.darkPrimaryText
    }
  }

  /// Secondary text (buttons, captions) — primary at ~75% opacity.
  var secondaryText: Color {
    primaryText.opacity(0.75)
  }

  /// Border/divider (e.g. input stroke) — primary at low opacity.
  var borderOpacity: Double { 0.15 }

  /// Current theme from UserDefaults; default is light.
  static func load() -> GeminiChatTheme {
    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.geminiChatTheme)
    return GeminiChatTheme(rawValue: raw ?? GeminiChatTheme.dark.rawValue) ?? .dark
  }

  /// Save current theme to UserDefaults.
  static func save(_ theme: GeminiChatTheme) {
    UserDefaults.standard.set(theme.rawValue, forKey: UserDefaultsKeys.geminiChatTheme)
  }
}
