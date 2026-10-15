#if !APP_STORE && canImport(Sparkle)
import AppKit
import Combine
import Foundation
import Sparkle

/// Wraps Sparkle 2 for the direct (GitHub) build. Never installs silently: Sparkle shows a notice
/// with the release notes and the user decides. Not compiled into the App Store build.
@MainActor
final class UpdaterService: NSObject, ObservableObject {
  static let shared = UpdaterService()

  @Published private(set) var canCheckForUpdates: Bool = false
  @Published private(set) var lastUpdateCheckDate: Date?

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
      DebugLogger.log("UPDATER: failed to start Sparkle: \(error.localizedDescription)")
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
    DebugLogger.log("UPDATER: started (feed \(AppConstants.sparkleFeedURL))")
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

  nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    if let error {
      DebugLogger.log("UPDATER: update cycle finished with error: \(error.localizedDescription)")
    } else {
      DebugLogger.log("UPDATER: update cycle finished")
    }
  }
}

extension UpdaterService: SPUStandardUserDriverDelegate {
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    true
  }

  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    guard !state.userInitiated else { return }
    DebugLogger.log("UPDATER: scheduled update found: \(update.displayVersionString)")
    // Menu-bar (LSUIElement) app: bring Sparkle's alert in front of other windows.
    Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
  }
}
#endif
