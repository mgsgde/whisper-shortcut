import SwiftUI

struct GoogleCalendarConnectionSection: View {
  @ObservedObject var oauthService = GoogleCalendarOAuthService.shared
  @State private var isAuthorizing = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Google Account",
        subtitle: "Connect your Google account to let Gemini access Calendar, Tasks, and Gmail"
      )

      HStack(spacing: 12) {
        if oauthService.isConnected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
          Text("Connected")
            .font(.callout)
            .foregroundColor(.primary)
          Spacer()
          Button("Disconnect") {
            oauthService.disconnect()
          }
        } else {
          Image(systemName: "circle")
            .foregroundColor(.secondary)
          Text("Not connected")
            .font(.callout)
            .foregroundColor(.secondary)
          Spacer()
          Button("Connect Google Account") {
            isAuthorizing = true
            errorMessage = nil
            Task {
              do {
                try await oauthService.startAuthorization()
              } catch {
                errorMessage = error.localizedDescription
              }
              isAuthorizing = false
            }
          }
          .disabled(isAuthorizing)
        }
      }

      if isAuthorizing {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Waiting for Google sign-in...")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundColor(.red)
      }
    }
  }
}
