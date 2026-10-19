import SwiftUI

/// "What's new in x.y" card on About, gated on last-seen version. Finding a newer version is
/// Sparkle's job in the direct build (`UpdatesSection`, `UpdaterService`); the App Store updates
/// itself.
struct WhatsNewSection: View {
  @State private var lastSeenVersion: String =
    UserDefaults.standard.string(forKey: UserDefaultsKeys.lastSeenWhatsNewVersion) ?? ""

  private var currentVersion: String { AppConstants.appVersion }
  private var showsWhatsNew: Bool { lastSeenVersion != currentVersion }

  var body: some View {
    if showsWhatsNew {
      VStack(spacing: 0) {
        whatsNewCard
        SpacedSectionDivider()
      }
    }
  }

  @ViewBuilder
  private var whatsNewCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("What's new in \(currentVersion)")
        .font(.callout)
        .fontWeight(.semibold)
      Text("You just updated. Replay the Welcome Tour below, or read the full notes on GitHub.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Button("Dismiss") { dismissWhatsNew() }
          .buttonStyle(.bordered)
          .pointerCursorOnHover()
        if let notesURL = URL(string: "\(AppConstants.githubRepositoryURL)/releases") {
          Link("Release notes", destination: notesURL)
            .font(.callout)
            .pointerCursorOnHover()
        }
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
        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
    )
  }

  private func dismissWhatsNew() {
    UserDefaults.standard.set(currentVersion, forKey: UserDefaultsKeys.lastSeenWhatsNewVersion)
    lastSeenVersion = currentVersion
  }
}
