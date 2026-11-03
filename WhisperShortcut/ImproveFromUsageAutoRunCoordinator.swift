import Foundation

/// Checks whether "Improve from usage" should run automatically based on the user's interval
/// setting and last run date. Runs on launch and on a daily timer when the app stays open.
@MainActor
final class ImproveFromUsageAutoRunCoordinator {
  static let shared = ImproveFromUsageAutoRunCoordinator()

  private static let timerInterval: TimeInterval = 24 * 60 * 60  // 24 hours

  /// How far short of `days × 86400` a check may still count as due. The 24 h timer is anchored
  /// to launch, not to the run start, so a run started from a Settings interval change (or a
  /// launch at another time of day) is out of step with it by up to 24 h. Half a day lets the
  /// nearest check on either side of the due time run it; after that run the stamp and the timer
  /// are one period apart, so later runs land on the timer ticks. `dateComponents([.day])` used to
  /// drop the remainder and wait a full extra day.
  nonisolated static let dueSlack: TimeInterval = 12 * 60 * 60

  private var dailyTimer: Timer?

  private init() {}

  /// Call on app launch and when the user changes the interval in Settings.
  /// If the chosen interval has elapsed since the last run (or there was no run yet), starts improvement.
  func checkAndRunIfDue() async {
    // A sidecar shares the user's data directory and must not run the daily job a second time.
    guard !AppConstants.isSidecarInstance else { return }
    // Writing Style does not depend on "Save usage data", so it runs first.
    // Detached: the review panel can wait on the user indefinitely and must not block the rest.
    Task { @MainActor in await WritingStyleAutoUpdater.shared.runIfDue() }
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
    let due = Self.isDue(lastRun: lastRun, now: now, intervalDays: days)
    if let last = lastRun {
      let elapsedDays = Int(now.timeIntervalSince(last) / 86_400)
      DebugLogger.log("AUTO-RUN: Interval \(days) days, last run \(elapsedDays) days ago, due: \(due)")
    } else {
      DebugLogger.log("AUTO-RUN: Interval \(days) days, no previous run, running now")
    }

    guard due else { return }

    // The run calls whatever improvement model is selected. A Gemini-only check skipped GPT,
    // Claude and local models that `runImprovementNow` already accepts.
    let improvementModel = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedImprovementModel,
      default: SettingsDefaults.selectedImprovementModel)
    guard improvementModel.provider.hasCredential else {
      DebugLogger.log("AUTO-RUN: No credential for \(improvementModel.displayName), skipping Improve from usage")
      return
    }

    DebugLogger.log("AUTO-RUN: Starting Improve from usage")
    await AutoPromptImprovementScheduler.shared.runImprovementNow(fromAutoRun: true)
  }

  /// Starts a repeating 24h timer so that auto-run is checked even when the app is not restarted.
  /// Call once after launch (e.g. from FullAppDelegate). Safe to call multiple times; only one timer is active.
  func startDailyTimer() {
    guard !AppConstants.isSidecarInstance else { return }
    guard dailyTimer == nil else { return }
    dailyTimer = Timer.scheduledTimer(withTimeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        await self?.checkAndRunIfDue()
      }
    }
    DebugLogger.log("AUTO-RUN: Daily check timer started")
  }

  /// True when `intervalDays` have elapsed since `lastRun`, with `dueSlack` so a check that
  /// lands up to half a day early still runs (the shortest interval is 3 days, so a run can
  /// never repeat within a day). A missing last run is due.
  nonisolated static func isDue(
    lastRun: Date?, now: Date, intervalDays: Int, slack: TimeInterval? = nil
  ) -> Bool {
    guard let lastRun else { return true }
    let allowedShortfall = slack ?? dueSlack
    return now.timeIntervalSince(lastRun) >= Double(intervalDays) * 86_400 - allowedShortfall
  }
}
