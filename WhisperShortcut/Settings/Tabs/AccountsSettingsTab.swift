import SwiftUI

/// Accounts Settings Tab — every credential in one place: the AI providers (OpenRouter and the four
/// API keys) and the services the chat connects to (Google, Trello, mailboxes).
///
/// Feature tabs only *pick* a model and point here when its provider is missing. Before this tab the
/// keys sat in General, the Google/Trello/mail connections in Chat, and messages sent people to
/// whichever of the two the author remembered.
struct AccountsSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  // Only the Google key is mirrored on `SettingsViewModel` (its save path runs through
  // `saveSettings`); the other three are owned by their section and persisted straight to the
  // Keychain on edit.
  @State private var xaiKey: String = ""
  @State private var anthropicKey: String = ""
  @State private var openAIKey: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      AccountsGroupHeader(
        title: "AI Providers",
        subtitle: "Connect at least one. Every feature then lets you pick a model from the providers connected here. Offline models need none of this."
      )

      // First because it is the shortest path: one sign-in, every model, no key to paste.
      OpenRouterConnectionSection()

      SpacedSectionDivider()

      APIKeyEntrySection(
        provider: .google,
        key: $viewModel.data.googleAPIKey,
        focusBinding: $focusedField,
        focusField: .googleAPIKey)

      SpacedSectionDivider()

      APIKeyEntrySection(provider: .openai, key: $openAIKey)

      SpacedSectionDivider()

      APIKeyEntrySection(provider: .anthropic, key: $anthropicKey)

      SpacedSectionDivider()

      APIKeyEntrySection(provider: .xai, key: $xaiKey)

      SpacedSectionDivider()

      AccountsGroupHeader(
        title: "Connected Services",
        subtitle: "Optional. Lets the chat look things up for you. Everything is read-only unless a section says otherwise."
      )

      GoogleCalendarConnectionSection()

      SpacedSectionDivider()

      TrelloConnectionSection()

      SpacedSectionDivider()

      MailAccountsSection()
    }
  }
}

/// Small group label above a run of sections, so a long tab reads as two lists rather than one.
struct AccountsGroupHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)
        .tracking(0.6)
      Text(subtitle)
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, SettingsConstants.sectionSpacing)
  }
}
