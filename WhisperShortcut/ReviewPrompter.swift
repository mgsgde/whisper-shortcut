import Foundation
import StoreKit
import AppKit

/// Manages two distinct review/support prompts depending on how the app was distributed:
///
/// - **App Store build**: native `SKStoreReviewController.requestReview()` after enough
///   successful operations. Apple's own system additionally rate-limits this to 3×/year.
/// - **GitHub build**: one-time NSAlert pointing the user at the App Store version
///   ("If you like this, please consider supporting me by buying it for a few euros and
///   leaving a review"). Shown at most once per installation.
///
/// Distribution is detected at runtime via the presence of an App Store receipt — no
/// build-config / scheme split needed.
///
/// Timing: `recordSuccessfulOperation()` never shows the prompt immediately. Instead it
/// sets a "pending" flag once the threshold is reached; the prompt then fires the next
/// time the user focuses this app (status-item menu open or chat window open). This
/// avoids stealing focus from the foreground app the user was just dictating into.
final class ReviewPrompter {

  // MARK: - Tuning
  private enum Constants {
    /// App Store: threshold for triggering the native review prompt.
    static let appStoreOperationThreshold = 10
    /// GitHub: higher threshold — this is a stronger ask ("buy it"), so wait until
    /// the user has clearly gotten value out of the app.
    static let githubOperationThreshold = 20
    /// Don't show the App Store prompt more than once per this period (Apple's own
    /// limit is 3×/365d; we add our own backstop on top).
    static let minimumDaysBetweenPrompts: Double = 30
  }

  static let shared = ReviewPrompter()

  /// Deep link that opens the Mac App Store review sheet for this app. Also used by the
  /// permanent "Rate WhisperShortcut" menu item — unlike the automatic prompt, that path
  /// is not subject to Apple's 3×/365d rate limit.
  static let writeReviewURL = URL(string: "macappstore://apps.apple.com/app/id6749648401?action=write-review")!

  private init() {}

  // MARK: - Public API

  /// Record one successful operation. Once the per-distribution threshold is reached
  /// (and any cooldown has expired), arms a pending prompt that fires on the next
  /// menu-bar open via `showPendingPromptIfNeeded()`.
  ///
  /// Marked `@MainActor` so all counter mutation happens on a single thread —
  /// otherwise concurrent successful operations could lose increments via the
  /// non-atomic read/write of UserDefaults.
  @MainActor
  func recordSuccessfulOperation() {
    let newCount = UserDefaults.standard.integer(forKey: UserDefaultsKeys.successfulOperationsCount) + 1
    UserDefaults.standard.set(newCount, forKey: UserDefaultsKeys.successfulOperationsCount)

    let threshold = currentThreshold()
    DebugLogger.log("REVIEW: Successful operation recorded. Count: \(newCount)/\(threshold) (\(distribution))")

    guard newCount >= threshold else { return }

    if !canShowPromptForCurrentDistribution() {
      // Threshold reached but eligibility check (cooldown / one-shot) said no.
      // Reset so we don't re-check on every subsequent op until the next full window.
      resetCounter()
      return
    }

    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.pendingReviewPrompt)
    DebugLogger.log("REVIEW: Threshold reached — armed pending prompt, will fire on next menu open")
  }

  /// Called when the user focuses this app (`menuWillOpen` on the status-item menu,
  /// or chat window open). If a pending prompt is armed, shows it now.
  @MainActor
  func showPendingPromptIfNeeded() {
    guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.pendingReviewPrompt) else { return }
    guard canShowPromptForCurrentDistribution() else {
      // Eligibility expired (e.g. shown via another path). Disarm.
      UserDefaults.standard.set(false, forKey: UserDefaultsKeys.pendingReviewPrompt)
      return
    }

    UserDefaults.standard.set(false, forKey: UserDefaultsKeys.pendingReviewPrompt)
    resetCounter()

    switch distribution {
    case .appStore:
      showAppStorePrompt()
    case .github:
      showGitHubSupportPrompt()
    }
  }

  // MARK: - Distribution detection

  private enum Distribution: CustomStringConvertible {
    case appStore
    case github
    var description: String {
      switch self {
      case .appStore: return "AppStore"
      case .github: return "GitHub"
      }
    }
  }

  private var distribution: Distribution {
    // App Store installs ship with a receipt file at this path; GitHub/direct
    // distributions do not. Reliable across Mac App Store TestFlight + production.
    guard let receiptURL = Bundle.main.appStoreReceiptURL else { return .github }
    return FileManager.default.fileExists(atPath: receiptURL.path) ? .appStore : .github
  }

  private func currentThreshold() -> Int {
    switch distribution {
    case .appStore: return Constants.appStoreOperationThreshold
    case .github: return Constants.githubOperationThreshold
    }
  }

  private func canShowPromptForCurrentDistribution() -> Bool {
    switch distribution {
    case .appStore:
      return isPastAppStoreCooldown()
    case .github:
      // Strictly one-shot per installation — independent of any counter cooldown.
      return !UserDefaults.standard.bool(forKey: UserDefaultsKeys.githubSupportPromptShown)
    }
  }

  private func isPastAppStoreCooldown() -> Bool {
    guard let last = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastReviewPromptDate) as? Date else {
      return true
    }
    let days = Date().timeIntervalSince(last) / 86_400
    return days >= Constants.minimumDaysBetweenPrompts
  }

  // MARK: - App Store prompt

  private func showAppStorePrompt() {
    SKStoreReviewController.requestReview()
    UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastReviewPromptDate)
    DebugLogger.log("REVIEW: App Store review prompt requested")
  }

  // MARK: - GitHub one-time support prompt

  private func showGitHubSupportPrompt() {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.githubSupportPromptShown)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Hey, I'm Magnus — the developer"
    alert.informativeText = """
      If you enjoy WhisperShortcut, feel free to buy it on the App Store and leave a \
      short review. It really helps me out as a solo developer.

      Best wishes from Heidelberg, Germany
      """
    alert.addButton(withTitle: "Open App Store")
    alert.addButton(withTitle: "Maybe Later")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      let url = URL(string: "https://apps.apple.com/us/app/whispershortcut/id6749648401")!
      NSWorkspace.shared.open(url)
      DebugLogger.log("REVIEW: GitHub user opened App Store from support prompt")
    } else {
      DebugLogger.log("REVIEW: GitHub user dismissed support prompt")
    }
  }

  // MARK: - Counter housekeeping

  // Note: the counter deliberately survives app updates. It used to reset on every
  // version change, but with a release cadence of ~1 version/day the App Store
  // auto-update reset it before active users ever reached the threshold — the prompt
  // effectively never fired. Over-prompting is already guarded by the 30-day cooldown
  // and Apple's own 3×/365d system limit.
  private func resetCounter() {
    UserDefaults.standard.set(0, forKey: UserDefaultsKeys.successfulOperationsCount)
  }
}
