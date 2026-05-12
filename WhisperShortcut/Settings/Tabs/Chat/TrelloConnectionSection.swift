import AppKit
import SwiftUI

/// Settings UI for the Trello integration.
///
/// Single-button flow: user types their Power-Up API key and clicks
/// "Connect Trello". The app saves the key and opens the browser to Trello's
/// authorize page. After the user clicks "Allow", Trello shows the token on a
/// page — the user copies it back into the field that appears in the UI, and
/// the app stores the token in the Keychain.
struct TrelloConnectionSection: View {
  @ObservedObject var oauthService = TrelloOAuthService.shared

  @State private var apiKey: String = KeychainManager.shared.getTrelloAPIKey() ?? ""
  @State private var token: String = ""
  @State private var awaitingToken: Bool = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Trello",
        subtitle: "Connect your Trello account to let the chat read and edit boards, lists, and cards"
      )

      if oauthService.isConnected {
        connectedView
      } else {
        connectFlowView
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundColor(.red)
      }
    }
  }

  // MARK: - Connected

  private var connectedView: some View {
    HStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.green)
      Text("Connected")
        .font(.callout)
      Spacer()
      Button("Disconnect") {
        oauthService.disconnect()
        token = ""
        awaitingToken = false
        errorMessage = nil
      }
    }
  }

  // MARK: - Connect Flow (single button)

  private var connectFlowView: some View {
    VStack(alignment: .leading, spacing: 12) {
      // API key field
      VStack(alignment: .leading, spacing: 6) {
        Text("Trello Power-Up API key")
          .font(.callout)
          .fontWeight(.medium)
        SecureField("Paste your Trello API key", text: $apiKey)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)

        HStack(spacing: 6) {
          Text("Get your key:")
            .font(.caption)
            .foregroundColor(.secondary)
          Button {
            NSWorkspace.shared.open(TrelloOAuthConfig.powerUpAdminURL)
          } label: {
            Text("trello.com/power-ups/admin")
              .font(.caption)
              .underline()
          }
          .buttonStyle(.link)
        }

        Text("Create a Power-Up (any name, your own workspace), open its \"API key\" tab and copy the key.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      // Step 2 only after the user has started the authorization
      if awaitingToken {
        VStack(alignment: .leading, spacing: 6) {
          Text("Paste the token shown by Trello in the browser")
            .font(.callout)
            .fontWeight(.medium)
          HStack(spacing: 8) {
            SecureField("Token from Trello", text: $token)
              .textFieldStyle(.roundedBorder)
              .disableAutocorrection(true)
              .onSubmit { saveToken() }
            Button("Save") { saveToken() }
              .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          Text("If the browser didn't open, click \"Connect Trello\" again.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      // Primary action
      HStack(spacing: 8) {
        Image(systemName: "circle")
          .foregroundColor(.secondary)
        Text("Not connected")
          .font(.callout)
          .foregroundColor(.secondary)
        Spacer()
        Button(awaitingToken ? "Re-open browser" : "Connect Trello") {
          startConnect()
        }
        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  // MARK: - Actions

  private func startConnect() {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else { return }

    // Persist API key so TrelloOAuthConfig.apiKey can read it.
    if !KeychainManager.shared.saveTrelloAPIKey(trimmedKey) {
      errorMessage = "Failed to save the API key to the Keychain."
      return
    }
    apiKey = trimmedKey
    errorMessage = nil

    do {
      try oauthService.openAuthorizationInBrowser()
      awaitingToken = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func saveToken() {
    do {
      try oauthService.submitToken(token)
      token = ""
      awaitingToken = false
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
