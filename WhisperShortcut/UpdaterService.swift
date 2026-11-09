#if !APP_STORE && canImport(Sparkle)
import AppKit
import Combine
import Foundation
import os
import Sparkle

/// Wraps Sparkle 2 for the direct (GitHub) build. Never installs silently: Sparkle shows a notice
/// with the release notes and the user decides. Not compiled into the App Store build.
@MainActor
final class UpdaterService: NSObject, ObservableObject {
  static let shared = UpdaterService()

  @Published private(set) var canCheckForUpdates: Bool = false
  @Published private(set) var lastUpdateCheckDate: Date?
  /// Feed the direct build checks. Stable until the user picks Latest. See `UpdateChannel`.
  @Published private(set) var channel: UpdateChannel = UpdateChannel.current()

  /// Bridges `SPUUpdater.automaticallyChecksForUpdates` for the Settings toggle.
  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set {
      objectWillChange.send()
      controller.updater.automaticallyChecksForUpdates = newValue
      DebugLogger.log("UPDATER: automatic checks \(newValue ? "enabled" : "disabled")")
    }
  }

  private var controller: SPUStandardUpdaterController!
  /// A scheduled update that arrived while a meeting recorded or Dictate Live ran and was held back
  /// (see `standardUserDriverShouldHandleShowingScheduledUpdate`). Shown when that ends.
  private var deferredScheduledUpdate = false
  /// True from the start of a Dictate Live recording until its last piece is inserted. A lock, not
  /// MainActor state, because Sparkle's delegate callbacks are nonisolated.
  nonisolated private static let dictateLiveActive = OSAllocatedUnfairLock(initialState: false)

  /// Set by `MenuBarController` when Dictate Live starts and clears.
  nonisolated static func setDictateLiveActive(_ active: Bool) {
    dictateLiveActive.withLock { $0 = active }
  }
  private var started = false
  private var observations: [NSKeyValueObservation] = []

  private override init() {
    super.init()
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
  }

  /// Idempotent. Called once from `applicationDidFinishLaunching`.
  func start() {
    guard !started else { return }
    started = true
    let updater = controller.updater
    do {
      try updater.start()
    } catch {
      DebugLogger.log("UPDATER: failed to start Sparkle: \(error.logDescription)")
    }
    updater.automaticallyDownloadsUpdates = false

    canCheckForUpdates = updater.canCheckForUpdates
    lastUpdateCheckDate = updater.lastUpdateCheckDate
    observations = [
      updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
        let value = change.newValue ?? false
        Task { @MainActor in self?.canCheckForUpdates = value }
      },
      updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
        let value = updater.lastUpdateCheckDate
        Task { @MainActor in self?.lastUpdateCheckDate = value }
      },
    ]
    DebugLogger.log("UPDATER: started (channel \(channel.rawValue))")
  }

  /// Persists the channel and, once Sparkle is running, reschedules the check so the next cycle
  /// reads the new channel.
  func setChannel(_ newValue: UpdateChannel) {
    UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaultsKeys.updateChannel)
    channel = newValue
    DebugLogger.log("UPDATER: channel \(newValue.rawValue)")
    if started {
      controller.updater.resetUpdateCycleAfterShortDelay()
    }
  }

  /// Called when a live meeting or Dictate Live has finished. A held-back scheduled update is brought up now;
  /// Sparkle keeps that update session open and shows it in focus on the next check.
  func showDeferredUpdateIfAny() {
    guard deferredScheduledUpdate else { return }
    deferredScheduledUpdate = false
    DebugLogger.log("UPDATER: meeting or dictation ended, showing the deferred scheduled update")
    controller.checkForUpdates(nil)
  }

  /// User-initiated check.
  func checkForUpdates() {
    DebugLogger.log("UPDATER: user-initiated check")
    controller.checkForUpdates(nil)
  }
}

extension UpdaterService: SPUUpdaterDelegate {
  nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
    #if DEBUG
    if let override = UserDefaults.standard.string(forKey: "SparkleFeedURLOverride"), !override.isEmpty {
      DebugLogger.log("UPDATER: using feed override \(override)")
      return override
    }
    #endif
    return AppConstants.sparkleFeedURL
  }

  /// Stable allows no extra channel (untagged items only). Latest also allows `latest`.
  nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    UpdateChannel.current().allowedSparkleChannels
  }

  nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    if let error {
      DebugLogger.log("UPDATER: update cycle finished with error: \(error.logDescription)")
    } else {
      DebugLogger.log("UPDATER: update cycle finished")
      // Sparkle only reports "no update" here, never the feed's newest version, so the log
      // cannot compare the two without new plumbing. Record what the client is and which
      // channel it reads: a "no update found" on Stable may simply mean the channel is
      // behind the newest release, not that the app is current. Latest sees every release.
      let channel = UpdateChannel.current()
      let hint =
        channel == .stable
        ? "; on Stable this can mean the channel is behind the newest release"
        : "; Latest sees every published release"
      DebugLogger.log(
        "UPDATER: no update found for \(AppConstants.appVersion) (build \(AppConstants.appBuildNumber)) "
          + "on channel \(channel.rawValue)" + hint
      )
    }
  }
}

extension UpdaterService: SPUStandardUserDriverDelegate {
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    // A scheduled update must not pop a window (and steal focus) while this process records a
    // live meeting or inserts Dictate Live pieces. Declining here defers it until that ends.
    if Self.thisProcessIsBusyWithLiveWork() {
      DebugLogger.log(
        "UPDATER: deferring scheduled update \(update.displayVersionString) (meeting recording or Dictate Live)")
      Task { @MainActor in UpdaterService.shared.deferredScheduledUpdate = true }
      return false
    }
    return true
  }

  nonisolated private static func thisProcessIsBusyWithLiveWork() -> Bool {
    thisProcessIsRecordingMeeting() || dictateLiveActive.withLock { $0 }
  }

  /// True when the live-meeting marker belongs to this process (written at session start, cleared
  /// at the end). File-based so it is safe from Sparkle's nonisolated delegate callbacks.
  nonisolated private static func thisProcessIsRecordingMeeting() -> Bool {
    guard let payload = LiveMeetingRecordingMarker.read()?.payload else { return false }
    return payload.pid == getpid()
  }

  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    guard !state.userInitiated else { return }
    guard handleShowingUpdate, !Self.thisProcessIsBusyWithLiveWork() else { return }
    DebugLogger.log("UPDATER: scheduled update found: \(update.displayVersionString)")
    // Menu-bar (LSUIElement) app: bring Sparkle's alert in front of other windows.
    Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
  }
}
#endif
