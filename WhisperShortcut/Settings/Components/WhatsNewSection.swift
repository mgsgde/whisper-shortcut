import SwiftUI

/// "What's new in x.y" card on About, gated on last-seen version. The non-App-Store build
/// also checks GitHub Releases for a newer tag and offers a Download link. Sparkle is out of scope.
struct WhatsNewSection: View {
  @State private var lastSeenVersion: String =
    UserDefaults.standard.string(forKey: UserDefaultsKeys.lastSeenWhatsNewVersion) ?? ""
  @State private var latestTag: String?
  @State private var latestURL: URL?

  private var currentVersion: String { AppConstants.appVersion }
  private var showsWhatsNew: Bool { lastSeenVersion != currentVersion }

  #if !APP_STORE
  private var updateAvailable: Bool {
    guard let latestTag else { return false }
    return Self.isVersion(latestTag, newerThan: currentVersion)
  }
  #endif

  private var hasContent: Bool {
    if showsWhatsNew { return true }
    #if !APP_STORE
    return updateAvailable
    #else
    return false
    #endif
  }

  var body: some View {
    Group {
      if hasContent {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
            if showsWhatsNew {
              whatsNewCard
            }
            #if !APP_STORE
            if updateAvailable, let latestTag, let latestURL {
              updateCard(tag: latestTag, url: latestURL)
            }
            #endif
          }
          SpacedSectionDivider()
        }
      }
    }
    #if !APP_STORE
    .task { await checkGitHubLatest() }
    #endif
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

  #if !APP_STORE
  @ViewBuilder
  private func updateCard(tag: String, url: URL) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Version \(Self.displayTag(tag)) is available")
        .font(.callout)
        .fontWeight(.semibold)
      Text("You're on \(currentVersion). Download the latest signed build from GitHub Releases.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Link("Download", destination: url)
        .font(.callout)
        .pointerCursorOnHover()
    }
    .padding(SettingsConstants.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(Color.accentColor.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
    )
  }

  private func checkGitHubLatest() async {
    let repoPath = AppConstants.githubRepositoryURL
      .replacingOccurrences(of: "https://github.com/", with: "")
    guard let url = URL(string: "https://api.github.com/repos/\(repoPath)/releases/latest") else { return }
    var request = URLRequest(url: url)
    request.setValue("WhisperShortcut/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    do {
      // `LLMHTTPSession.integrations`, not `URLSession.shared`: only a session the app
      // configures itself carries the Offline Mode guard, and this check is the one call in
      // the app that would otherwise reach the internet while the mode is on.
      let (data, response) = try await LLMHTTPSession.integrations.data(for: request)
      if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        DebugLogger.log("WHATS-NEW: GitHub releases HTTP \(http.statusCode)")
        return
      }
      let decoded = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
      await MainActor.run {
        latestTag = decoded.tagName
        latestURL = URL(string: decoded.htmlURL)
      }
    } catch {
      DebugLogger.log("WHATS-NEW: GitHub check failed: \(error.localizedDescription)")
    }
  }
  #endif

  private func dismissWhatsNew() {
    UserDefaults.standard.set(currentVersion, forKey: UserDefaultsKeys.lastSeenWhatsNewVersion)
    lastSeenVersion = currentVersion
  }

  static func isVersion(_ remote: String, newerThan local: String) -> Bool {
    let r = displayTag(remote)
    return r.compare(local, options: .numeric) == .orderedDescending
  }

  static func displayTag(_ tag: String) -> String {
    var trimmed = tag
    if trimmed.first == "v" || trimmed.first == "V" {
      trimmed.removeFirst()
    }
    return trimmed
  }
}

private struct GitHubLatestRelease: Decodable {
  let tagName: String
  let htmlURL: String

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
  }
}
