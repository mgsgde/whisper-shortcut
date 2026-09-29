import SwiftUI

/// Whether Dictate Prompt may look things up with read-only tools. Shown in Settings → Dictate
/// Prompt. Read by `DictatePromptAgent.isEnabledInSettings`.
struct DictatePromptToolsSection: View {
  @AppStorage(UserDefaultsKeys.dictatePromptToolsEnabled) private var enabled = true

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Look things up",
        systemImage: "magnifyingglass",
        subtitle: "Dictate Prompt can read your calendar, tasks, email, Trello and shared folders when an instruction needs a fact."
      )

      Toggle(isOn: $enabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Let Dictate Prompt use read-only tools")
            .font(.callout)
          Text("Only for Gemini models, and only for what you have connected in Settings → Chat. Nothing is changed, created or sent. A lookup adds a few seconds to that one request.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
    }
  }
}
