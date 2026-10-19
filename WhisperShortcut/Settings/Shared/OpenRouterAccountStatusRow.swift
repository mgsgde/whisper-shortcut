import SwiftUI

/// "Account: Connected" / "Not connected — Connect in General…" for the sections that *use* the
/// OpenRouter account (Settings → Dictate, Settings → Chat).
///
/// The account itself is connected in exactly one place, `OpenRouterConnectionSection` on the
/// General tab. Repeating the full connect form in every tab that needs it made the same
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
        Label("Connected in Settings → General", systemImage: "checkmark.circle.fill")
          .labelStyle(TintedIconLabelStyle(tint: .green))
      } else {
        Label("Not connected", systemImage: "exclamationmark.circle.fill")
          .labelStyle(TintedIconLabelStyle(tint: .orange))

        Button("Connect in General…") {
          SettingsManager.shared.showSettings(tab: .general)
        }
        .help("OpenRouter is connected once, in Settings → General, and shared by Dictate and Chat.")
      }

      Spacer()
    }
  }
}

/// Icon tinted, text in the secondary colour — a status reads at a glance without the whole line
/// shouting.
private struct TintedIconLabelStyle: LabelStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.foregroundColor(tint)
      configuration.title.foregroundColor(.secondary)
    }
    .font(.callout)
  }
}
