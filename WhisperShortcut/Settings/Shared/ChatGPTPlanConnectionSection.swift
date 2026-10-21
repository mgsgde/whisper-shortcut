import SwiftUI

/// Sign in with ChatGPT so Chat runs on the user's ChatGPT plan instead of an API key.
///
/// Lives on the Accounts tab next to the other providers; Settings → Chat only shows
/// `ChatGPTPlanAccountStatusRow` and links back here, the same split OpenRouter uses. Direct-download
/// build only: OpenAI's self-serve flow is for open-source apps, the paid App Store build needs
/// OpenAI's approval first.
///
/// The button label and the first-sign-in notice follow OpenAI's Sign in with ChatGPT UI
/// guidelines (developers.openai.com/siwc/ui-ux-guidelines): "Continue with ChatGPT", and one
/// "You're using your ChatGPT plan" message the first time plan use is on.
struct ChatGPTPlanConnectionSection: View {
  @ObservedObject private var service = ChatGPTPlanOAuthService.shared

  @State private var errorMessage: String?
  @State private var signOutWarning: String?
  @State private var showsFirstUseNotice = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "ChatGPT",
        systemImage: "person.crop.circle.badge.checkmark",
        subtitle: "Use your ChatGPT Plus or Pro plan in Chat. Sign in once, no API key."
      )

      statusRow

      if service.isBusy {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Waiting for ChatGPT sign-in in your browser…")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      if let message = errorMessage ?? service.lastError {
        Text(message)
          .font(.caption)
          .foregroundColor(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let signOutWarning {
        Text(signOutWarning)
          .font(.caption)
          .foregroundColor(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text("Covers Chat only. Dictation still needs an on-device model or an API key, because ChatGPT plans can't be used for transcription in other apps.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear { service.refreshState() }
    .alert("You're using your ChatGPT plan", isPresented: $showsFirstUseNotice) {
      Button("Got it") {}
      Button("Manage usage") { NSWorkspace.shared.open(ChatGPTPlanOAuthConfig.usageSettingsURL) }
    } message: {
      Text("Chat requests in WhisperShortcut now count toward your ChatGPT plan. You can set a weekly limit for this app in ChatGPT Settings → Usage.")
    }
  }

  // MARK: - Status

  @ViewBuilder
  private var statusRow: some View {
    if let email = service.accountEmail, !service.needsSignIn {
      if service.planEnabled {
        HStack(spacing: 12) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
          Text("Signed in as \(email)")
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Link("Usage", destination: ChatGPTPlanOAuthConfig.usageSettingsURL)
            .font(.callout)
            .pointerCursorOnHover()
            .help("See and limit how much of your plan WhisperShortcut uses")
          Button("Sign Out") { signOut() }
            .disabled(service.isBusy)
        }
      } else {
        // Signed in, but the user declined plan use on the consent screen.
        HStack(spacing: 12) {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundColor(.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text("Signed in as \(email)")
              .font(.callout)
              .lineLimit(1)
              .truncationMode(.middle)
            Text("Plan use wasn't allowed, so Chat can't run on this account yet.")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
          Button("Allow Plan Use") { connect() }
            .disabled(service.isBusy)
          Button("Sign Out") { signOut() }
            .disabled(service.isBusy)
        }
      }
    } else {
      HStack(spacing: 12) {
        if service.needsSignIn, let email = service.accountEmail {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundColor(.orange)
          Text("Sign-in for \(email) expired")
            .font(.callout)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
          Image(systemName: "circle")
            .foregroundColor(.secondary)
          Text("Not signed in")
            .font(.callout)
            .foregroundColor(.secondary)
        }
        Spacer()
        ContinueWithChatGPTButton { connect() }
          .disabled(service.isBusy)
      }
    }
  }

  // MARK: - Actions

  private func connect() {
    errorMessage = nil
    signOutWarning = nil
    Task {
      do {
        let signedIn = try await service.connect()
        // The model list and the Chat picker depend on the session; re-check what is selectable.
        ModelSelectionReconciler.reconcileAll()
        if signedIn, service.planEnabled, !UserDefaults.standard.bool(forKey: UserDefaultsKeys.chatGPTPlanFirstUseNoticeShown) {
          UserDefaults.standard.set(true, forKey: UserDefaultsKeys.chatGPTPlanFirstUseNoticeShown)
          showsFirstUseNotice = true
        }
      } catch {
        // `service.lastError` carries the message; keep a local copy so a later refreshState()
        // cannot clear it while the user is still reading.
        errorMessage = error.localizedDescription
      }
    }
  }

  private func signOut() {
    errorMessage = nil
    signOutWarning = nil
    Task {
      let confirmed = await service.signOut()
      ModelSelectionReconciler.reconcileAll()
      if !confirmed {
        signOutWarning = "Signed out here, but ChatGPT didn't confirm it. To be sure, remove WhisperShortcut's access in ChatGPT Settings → Usage."
      }
    }
  }
}

/// OpenAI's sign-in button: black, white label, "Continue with ChatGPT". Kept as its own view so the
/// Welcome Tour can use the same button.
struct ContinueWithChatGPTButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("Continue with ChatGPT")
        .font(.callout.weight(.medium))
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .pointerCursorOnHover()
    .accessibilityLabel("Continue with ChatGPT")
  }
}

/// "Account: Signed in" / "Not signed in — Sign in in Accounts…" for Settings → Chat, mirroring
/// `OpenRouterAccountStatusRow`.
struct ChatGPTPlanAccountStatusRow: View {
  @ObservedObject private var service = ChatGPTPlanOAuthService.shared

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      Text("Account:")
        .font(.body)
        .fontWeight(.medium)
        .frame(width: SettingsConstants.labelWidth, alignment: .leading)

      if let email = service.accountEmail, service.planEnabled, !service.needsSignIn {
        Label("\(email) · signed in under Settings → Accounts", systemImage: "checkmark.circle.fill")
          .labelStyle(StatusIconLabelStyle(tint: .green))
          .lineLimit(1)
          .truncationMode(.middle)
      } else {
        Label(statusText, systemImage: "exclamationmark.circle.fill")
          .labelStyle(StatusIconLabelStyle(tint: .orange))

        Button("Sign In in Accounts…") {
          SettingsManager.shared.showSettings(tab: .accounts)
        }
        .help("ChatGPT is signed in once, in Settings → Accounts.")
      }

      Spacer()
    }
    .onAppear { service.refreshState() }
  }

  private var statusText: String {
    if service.needsSignIn { return "Sign-in expired" }
    if service.accountEmail != nil { return "Plan use not allowed" }
    return "Not signed in"
  }
}

/// Icon tinted, text secondary — same look as the OpenRouter status row.
private struct StatusIconLabelStyle: LabelStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.foregroundColor(tint)
      configuration.title.foregroundColor(.secondary)
    }
    .font(.callout)
  }
}
