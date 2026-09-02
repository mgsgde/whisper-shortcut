import AppKit
import SwiftUI

/// Permissions tab — macOS permission status and actions. This is the destination every
/// permission-error path routes to, and the same overview shown during onboarding.
struct PermissionsTab: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SectionHeader(
        title: "Privacy & Permissions",
        systemImage: "lock.shield",
        subtitle: "Whether anything may leave this Mac, and what WhisperShortcut can access on it."
      )

      Spacer().frame(height: SettingsConstants.sectionSpacing)

      OfflineModeSection()

      Spacer().frame(height: SettingsConstants.sectionSpacing)

      #if APP_STORE
      PermissionsOverview(mode: .settings, includeAccessibility: false)
      #else
      PermissionsOverview(mode: .settings, includeAccessibility: true)
      #endif
    }
  }
}

/// The one switch that makes the app device-local.
///
/// It sits in Privacy & Permissions rather than in Dictate settings because it is not a dictation
/// setting: it decides whether *anything* the app does may leave this Mac, which is the question
/// someone signing off on a data-protection concept is asking.
struct OfflineModeSection: View {
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false
  /// Set in `onAppear` — reading the filesystem for six model folders is not something to do in a
  /// property initializer that SwiftUI may re-run.
  @State private var hasOfflineModel = false

  var body: some View {
    offlineModeBlock
      .onAppear {
        hasOfflineModel = OfflineModelType.byAccuracy.contains {
          ModelManager.shared.isModelAvailable($0)
        }
      }
  }

  @ViewBuilder
  private var offlineModeBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Offline Mode", isOn: $offlineMode)
        .toggleStyle(.switch)
        .font(.headline)
        .onChange(of: offlineMode) { _, isOn in
          // Model selections are moved on the spot, so turning the switch on cannot leave a cloud
          // model selected behind a mode that then refuses it.
          ModelSelectionReconciler.reconcileAll()
          DebugLogger.log("OFFLINE-MODE: \(isOn ? "enabled" : "disabled")")
        }

      Text(
        "Everything runs on this Mac. Dictation uses an on-device Whisper model, no request may leave the machine, and no transcript, prompt or audio sample is written to the usage log. Built for regulated dictation — patient findings, case notes — where \"the recording never leaves this device\" has to hold whatever is configured."
      )
      .font(.callout)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)

      if offlineMode {
        VStack(alignment: .leading, spacing: 6) {
          offlineModeBullet("Dictation and Dictate Prompt stay on this Mac — Whisper here, and an in-process MLX model (or Ollama / LM Studio) for the rewrite.")
          offlineModeBullet("Chat can run on the same offline MLX models. Read Aloud uses on-device macOS voices. Smart Improvement and the Google and Trello integrations do not work — nothing runs them on-device.")
          offlineModeBullet("Requests to your own machine or local network still work, so a Whisper server or Ollama on this network stays available. Downloading a Whisper or MLX model from Hugging Face still works (it carries no content of yours).")
          if !hasOfflineModel {
            WhisperModelDownloadCard(modelType: .whisperBase) {
              hasOfflineModel = true
            }
          }
        }
        .padding(.top, 2)
      }
    }
    .padding(SettingsConstants.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .stroke(offlineMode ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func offlineModeBullet(
    _ text: String, systemImage: String = "checkmark.circle.fill", color: Color = .green
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage)
        .font(.caption)
        .foregroundStyle(color)
      Text(text)
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }
}

/// Privacy promise, open-source banner, and policy link. Shown on the About tab; the switch that
/// actually changes behaviour lives in `OfflineModeSection` on Privacy & Permissions.
struct PrivacySection: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SectionHeader(
        title: "Privacy",
        systemImage: "hand.raised",
        subtitle: "What this app does — and doesn't do — with your data."
      )

      Spacer().frame(height: SettingsConstants.sectionSpacing)

      privacyPromiseBlock
    }
  }

  @ViewBuilder
  private var privacyPromiseBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "lock.shield")
          .font(.title3)
          .foregroundStyle(.tint)
        Text(PrivacyCopy.promiseTitle)
          .font(.headline)
      }
      OpenSourceBanner()
      ForEach(PrivacyCopy.promiseBullets, id: \.self) { bullet in
        promiseBullet(bullet)
      }
      HStack(spacing: 12) {
        Button {
          if let url = URL(string: AppConstants.privacyPolicyURL) {
            NSWorkspace.shared.open(url)
          }
        } label: {
          Label("View full privacy policy", systemImage: "doc.text")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .pointerCursorOnHover()
      }
      .padding(.top, 4)
    }
    .padding(SettingsConstants.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func promiseBullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
      Text(text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }
}

extension Notification.Name {
  /// Posted by failure-path dialogs (AccessibilityPermissionManager, screen-capture failure in
  /// ChatView, the screenshot popup) to open the Settings window and switch to the Permissions
  /// tab — the single hub. `SettingsView` observes this and updates `selectedTab`.
  static let openPrivacyPermissionsTab = Notification.Name("WhisperShortcut.openPrivacyPermissionsTab")
  /// Posted with a `SettingsTab.rawValue` object to switch the Settings sidebar.
  static let openSettingsTab = Notification.Name("WhisperShortcut.openSettingsTab")
  /// Posted when onboarding is finished so the menu bar can hide "Finish setup…".
  static let onboardingStatusDidChange = Notification.Name("WhisperShortcut.onboardingStatusDidChange")
}
