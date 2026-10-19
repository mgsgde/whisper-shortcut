import Foundation

/// Checks whether "Improve from usage" should run automatically based on the user's interval
/// setting and last run date. Runs on launch and on a daily timer when the app stays open.
@MainActor
final class ImproveFromUsageAutoRunCoordinator {
  static let shared = ImproveFromUsageAutoRunCoordinator()

  private static let timerInterval: TimeInterval = 24 * 60 * 60  // 24 hours

  private var dailyTimer: Timer?

  private init() {}

  /// Call on app launch and when the user changes the interval in Settings.
  /// If the chosen interval has elapsed since the last run (or there was no run yet), starts improvement.
  func checkAndRunIfDue() async {
    // Writing Style does not depend on "Save usage data", so it runs first.
    await WritingStyleAutoUpdater.shared.runIfDue()
    guard ContextLoggingPreference.isEnabled else {
      DebugLogger.log(
        "AUTO-RUN: Save usage data is off (or Offline Mode is on), skipping Improve from usage")
      return
    }
    let raw: Int
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.improveFromUsageAutoRunInterval) == nil {
      raw = ImproveFromUsageAutoRunInterval.every7Days.rawValue  // default when never set
    } else {
      raw = UserDefaults.standard.integer(forKey: UserDefaultsKeys.improveFromUsageAutoRunInterval)
    }
    let interval = ImproveFromUsageAutoRunInterval(rawValue: raw) ?? .every7Days
    guard let days = interval.dayCount else {
      DebugLogger.log("AUTO-RUN: Improve from usage auto-run is Off")
      return
    }

    let lastRun = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastAutoImprovementRunDate) as? Date
    let now = Date()
    let calendar = Calendar.current
    let due: Bool
    if let last = lastRun {
      let elapsed = calendar.dateComponents([.day], from: last, to: now).day ?? 0
      due = elapsed >= days
      DebugLogger.log("AUTO-RUN: Interval \(days) days, last run \(elapsed) days ago, due: \(due)")
    } else {
      due = true
      DebugLogger.log("AUTO-RUN: Interval \(days) days, no previous run, running now")
    }

    guard due else { return }

    // The selected improvement model's own provider — not hardcoded to Gemini. A user with only
    // an OpenAI, xAI, or local setup used to never get an auto-run: this checked only for a
    // Gemini key while every other guard in this feature already follows the selected model.
    let improvementModel = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedImprovementModel,
      default: SettingsDefaults.selectedImprovementModel)
    guard improvementModel.provider.hasCredential else {
      DebugLogger.log(
        "AUTO-RUN: No credential for \(improvementModel.displayName), skipping Improve from usage")
      return
    }

    DebugLogger.log("AUTO-RUN: Starting Improve from usage")
    await AutoPromptImprovementScheduler.shared.runImprovementNow(fromAutoRun: true)
  }

  /// Starts a repeating 24h timer so that auto-run is checked even when the app is not restarted.
  /// Call once after launch (e.g. from FullAppDelegate). Safe to call multiple times; only one timer is active.
  func startDailyTimer() {
    guard dailyTimer == nil else { return }
    dailyTimer = Timer.scheduledTimer(withTimeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        await self?.checkAndRunIfDue()
      }
    }
    DebugLogger.log("AUTO-RUN: Daily check timer started")
  }
}
