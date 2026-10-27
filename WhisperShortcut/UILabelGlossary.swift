import Foundation

/// The README the in-app Chat reads (`read_whisper_shortcut_doc`) stays English, but on a German
/// Mac the user sees German labels. This table maps the README's English names to what is on
/// screen, so the Chat can answer "Einstellungen → Konten" instead of "Settings → Accounts".
/// The German side comes from the String Catalog, so there is no second copy of the translation.
enum UILabelGlossary {
  /// English label as written in the README, and the same label as the running app shows it.
  static var entries: [(english: String, onScreen: String)] {
    [
      ("Settings", String(localized: "Settings", comment: "Settings window and menu item")),
      ("General", String(localized: "General", comment: "Settings tab")),
      ("Accounts", String(localized: "Accounts", comment: "Settings tab")),
      ("Dictate", String(localized: "Dictate", comment: "Settings tab and feature")),
      ("Dictate Prompt", String(localized: "Dictate Prompt", comment: "Feature name")),
      ("Screenshot", String(localized: "Screenshot", comment: "Settings tab and feature")),
      ("Read Aloud", String(localized: "Read Aloud", comment: "Settings tab and feature")),
      ("Chat", String(localized: "Chat", comment: "Settings tab and feature")),
      ("Meetings", String(localized: "Meetings", comment: "Settings tab")),
      ("Smart Improvement", String(localized: "Smart Improvement", comment: "Settings tab")),
      ("Privacy & Permissions", String(localized: "Privacy & Permissions", comment: "Settings tab")),
      ("About", String(localized: "About", comment: "Settings tab")),
      ("Offline Mode", String(localized: "Offline Mode")),
      ("Glossary", String(localized: "Glossary", comment: "Dictation term list")),
      ("Auto-paste", String(localized: "Auto-paste")),
      ("Save usage data", String(localized: "Save usage data")),
      ("Welcome Tour", String(localized: "Welcome Tour")),
      ("Shortcuts", String(localized: "Shortcuts")),
      ("Send Feedback", String(localized: "Send Feedback")),
      ("Share Usage Report", String(localized: "Share Usage Report")),
    ]
  }

  /// Markdown appended to a doc when the app runs in a language other than English; empty in English.
  static func appendix(languageCode: String? = Bundle.main.preferredLocalizations.first) -> String {
    guard let languageCode, languageCode != "en" else { return "" }
    let rows = entries
      .filter { $0.english != $0.onScreen }
      .map { "| \($0.english) | \($0.onScreen) |" }
    guard !rows.isEmpty else { return "" }
    return """


      ## On-screen labels (app language: \(languageCode))

      This document uses the English names. The user sees the app in another language; when you \
      name a setting, menu item or tab, use the on-screen label from this table.

      | In this document | On screen |
      | --- | --- |
      \(rows.joined(separator: "\n"))
      """
  }
}
