//
//  LanguageSection.swift
//  WhisperShortcut
//

import AppKit
import SwiftUI

/// The app has no language picker of its own: it follows macOS, which also lets the user set
/// a language per app. This section says so and opens the right System Settings pane.
struct LanguageSection: View {
  private static let languageSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

  private var currentLanguageName: String {
    let code = Bundle.main.preferredLocalizations.first ?? "en"
    return Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Language",
        systemImage: "globe",
        subtitle: "WhisperShortcut follows the language of macOS"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("App language:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Text(verbatim: currentLanguageName)
          .font(.body)

        Spacer()

        Button("Change in System Settings…") {
          NSWorkspace.shared.open(Self.languageSettingsURL)
        }
      }

      Text("To use a different language for this app only, add WhisperShortcut under System Settings → General → Language & Region → Applications, then quit and reopen it.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
