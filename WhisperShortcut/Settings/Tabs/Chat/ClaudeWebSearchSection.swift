import SwiftUI

/// Whether Claude models may use Anthropic's server-side web search. Shown in Settings → Chat.
/// Unlike the other providers' search it is billed per search on the user's own key, so it gets
/// an off switch. Read by `AnthropicChatProvider.isWebSearchEnabledInSettings`.
struct ClaudeWebSearchSection: View {
  @AppStorage(UserDefaultsKeys.claudeWebSearchEnabled) private var enabled = true

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Web Search for Claude",
        systemImage: "globe",
        subtitle: "Claude models can search the web for current information and show their sources under each paragraph."
      )

      Toggle(isOn: $enabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Let Claude search the web")
            .font(.callout)
          Text("Anthropic bills $10 per 1,000 searches on your API key, plus the tokens of the results. Claude searches at most 5 times per message, and only when a question needs current information.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
    }
  }
}
