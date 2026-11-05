import SwiftUI

/// The **Own server** entry on Settings → Accounts: the place a user looking for "how do I add a
/// provider" actually looks.
///
/// The form itself lives in `OwnServerEndpointSection`, which the Dictate, Dictate Prompt and Chat
/// tabs render among their model pickers. That is the right place to *use* the server and the wrong
/// place to *discover* it: a LiteLLM or LM Studio user has no reason to open a model picker to find
/// out the app can talk to their own endpoint. So Accounts carries the entry point and opens the
/// same form inline — no teleporting to another tab, because a user who just clicked "Set up" here
/// expects the fields to appear here.
///
/// `route: .chat` on purpose: that route shows both the chat and the transcription model field, so
/// one form covers Dictate, Dictate Prompt and Chat.
struct OwnServerAccountsSection: View {
  @State private var showsForm = false
  /// Mirrors `customOpenAIChatEndpointURL` so the status line follows the form and any change an AI
  /// app makes through MCP.
  @State private var baseURL: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Own server",
        systemImage: "server.rack",
        subtitle: "An OpenAI-compatible server you run or rent: LiteLLM, Azure OpenAI, Vertex AI, OpenInference, or a local one such as LM Studio, MLX or oMLX. One URL and key for Dictate, Dictate Prompt and Chat — the server must also serve /audio/transcriptions for Dictate and spoken Dictate Prompt. LM Studio and mlx_lm.server are chat-only."
      )

      if showsForm {
        // No header: this card already names the thing, and the form's own title would repeat it.
        OwnServerEndpointSection(route: .chat, showsHeader: false)

        HStack {
          Spacer().frame(width: SettingsConstants.labelWidth + 16)
          Button("Close") { showsForm = false }
        }
      } else {
        statusRow
      }
    }
    .onAppear { reload() }
    .onChange(of: showsForm) { _, _ in reload() }
    .onReceive(NotificationCenter.default.publisher(for: .settingsChangedExternally)) { _ in
      reload()
    }
  }

  // MARK: - Status

  /// Says whether a server is configured and which host it is, so the answer to "did that stick?"
  /// is visible without opening the form.
  private var statusRow: some View {
    HStack(spacing: 12) {
      if let host = configuredHost {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
        Text("Set up: \(host)")
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.middle)
      } else {
        Image(systemName: "circle")
          .foregroundColor(.secondary)
        Text("Not set up yet.")
          .font(.callout)
          .foregroundColor(.secondary)
      }

      Spacer()

      Button(actionTitle) { showsForm = true }
    }
  }

  /// `LocalizedStringKey` rather than `String` so both labels are extracted and translated.
  private var actionTitle: LocalizedStringKey {
    configuredHost == nil ? "Set up…" : "Edit server…"
  }

  // MARK: - State

  private var configuredHost: String? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let components = URLComponents(string: trimmed), let host = components.host else {
      return trimmed
    }
    return components.port.map { "\(host):\($0)" } ?? host
  }

  private func reload() {
    baseURL = UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL) ?? ""
  }
}
