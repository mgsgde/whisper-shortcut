import SwiftUI

/// "Account: Connected" / "Not connected — Connect in Accounts…" for the sections that *use* the
/// OpenRouter account (Settings → Dictate, Settings → Chat).
///
/// The account itself is connected in exactly one place, `OpenRouterConnectionSection` on the
/// Accounts tab. Repeating the full connect form in every tab that needs it made the same
/// credential look like several settings, so the consuming tabs show this status line instead.
struct OpenRouterAccountStatusRow: View {
  @ObservedObject private var oauthService = OpenRouterOAuthService.shared

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      Text("Account:")
        .font(.body)
        .fontWeight(.medium)
        .frame(width: SettingsConstants.labelWidth, alignment: .leading)

      if oauthService.isConnected {
        Label("Connected in Settings → Accounts", systemImage: "checkmark.circle.fill")
          .labelStyle(TintedIconLabelStyle(tint: .green))
      } else {
        Label("Not connected", systemImage: "exclamationmark.circle.fill")
          .labelStyle(TintedIconLabelStyle(tint: .orange))

        Button("Connect in Accounts…") {
          SettingsManager.shared.showSettings(tab: .accounts)
        }
        .help("OpenRouter is connected once, in Settings → Accounts, and shared by Dictate and Chat.")
      }

      Spacer()
    }
  }
}
