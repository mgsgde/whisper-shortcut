import SwiftUI

#if !APP_STORE && canImport(Sparkle)

/// Settings → About card for the direct build's Sparkle updater: manual check, the automatic-check
/// switch, and — because the pilot practice runs in Offline Mode — a plain statement of what the
/// check sends. Never offers to install silently; Sparkle's own window carries the release notes
/// and the Install button.
struct UpdatesSection: View {
  @ObservedObject private var updater = UpdaterService.shared
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false

  private var automaticChecks: Binding<Bool> {
    Binding(
      get: { updater.automaticallyChecksForUpdates },
      set: { updater.automaticallyChecksForUpdates = $0 }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: "arrow.down.circle")
          .font(.title2)
          .foregroundColor(.accentColor)

        VStack(alignment: .leading, spacing: 2) {
          Text("Updates")
            .font(.callout)
            .fontWeight(.medium)
          Text(statusLine)
            .font(.caption)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        }

        Spacer(minLength: 12)

        Button {
          updater.checkForUpdates()
        } label: {
          Text("Check for Updates…")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(!updater.canCheckForUpdates)
        .pointerCursorOnHover()
      }

      channelPicker

      Toggle("Check for updates automatically", isOn: automaticChecks)
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)

      Text(
        "When a new version is out, you see a notice with its release notes. Nothing is downloaded or installed until you click Install Update."
      )
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      if offlineMode {
        offlineModeNote
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
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  /// Stable is the default so a practice that works with the app all day only sees versions that
  /// already ran a week in daily use; Latest is for people who want every release the day it ships.
  private var channelPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker(
        "Update channel",
        selection: Binding(
          get: { updater.channel },
          set: { updater.setChannel($0) }
        )
      ) {
        Text("Stable").tag(UpdateChannel.stable)
        Text("Latest").tag(UpdateChannel.latest)
      }
      .pickerStyle(.segmented)
      .fixedSize()
      .font(.callout)

      Text(channelExplanation)
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var channelExplanation: String {
    switch updater.channel {
    case .stable:
      return String(
        localized:
          "Recommended for work. You get a new version only after it has run in daily use for about a week, at most every two weeks."
      )
    case .latest:
      return String(
        localized:
          "Every release on the day it ships, with the newest features and fixes. Switching back to Stable keeps your version; the next update comes once Stable is newer."
      )
    }
  }

  private var statusLine: String {
    let version = AppConstants.appVersion
    let build = AppConstants.appBuildNumber
    guard let last = updater.lastUpdateCheckDate else {
      return String(localized: "Version \(version) (build \(build))")
    }
    let checked = last.formatted(.relative(presentation: .named))
    return String(localized: "Version \(version) (build \(build)) · last checked \(checked)")
  }

  /// Offline Mode promises that nothing leaves the Mac; the update check is the one exception,
  /// so it says so where the switch is rather than in a footnote.
  private var offlineModeNote: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "network.badge.shield.half.filled")
        .font(.caption)
        .foregroundStyle(Color.accentColor)
      Text(
        "Allowed in Offline Mode: the update check is the only request that leaves this Mac. It downloads the list of releases from github.com and sends only the app's name and version — no recordings, transcripts, settings or usage data. Turn the switch off to stop automatic checks."
      )
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.accentColor.opacity(0.08))
    )
  }
}

#endif
