import AppKit
import SwiftUI

/// Permissions tab — macOS permission status and actions. This is the destination every
/// permission-error path routes to, and the same overview shown during onboarding.
struct PermissionsTab: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SectionHeader(
        title: "Permissions",
        subtitle: "What WhisperShortcut can access on your Mac. Status reflects what System Settings has granted."
      )

      Spacer().frame(height: SettingsConstants.sectionSpacing)

      #if APP_STORE
      PermissionsOverview(mode: .settings, includeAccessibility: false)
      #else
      PermissionsOverview(mode: .settings, includeAccessibility: true)
      #endif
    }
  }
}

/// Privacy promise, open-source banner, policy link, and welcome-tour replay.
struct PrivacySection: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SectionHeader(
        title: "Privacy",
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

        Button {
          relaunchWelcomeTour()
        } label: {
          Label("Show Welcome Tour again", systemImage: "sparkles")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .pointerCursorOnHover()
      }
      .padding(.top, 4)
    }
    .padding(16)
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

  private func relaunchWelcomeTour() {
    SettingsManager.shared.closeSettings()
    WelcomeWindowController.shared.show()
  }
}

extension Notification.Name {
  /// Posted by failure-path dialogs (AccessibilityPermissionManager, screen-capture failure in
  /// ChatView, the screenshot popup) to open the Settings window and switch to the Permissions
  /// tab — the single hub. `SettingsView` observes this and updates `selectedTab`.
  static let openPrivacyPermissionsTab = Notification.Name("WhisperShortcut.openPrivacyPermissionsTab")
}
