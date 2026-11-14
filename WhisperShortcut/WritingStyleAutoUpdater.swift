//
//  WritingStyleAutoUpdater.swift
//  WhisperShortcut
//
//  Keeps Writing Style learning on its own while the toggle is on: imports sent emails from Gmail
//  weekly and updates the profile once enough new samples have arrived. The profile review
//  panel still appears, so the user stays in control. Logs carry counts only, never text.
//

import Foundation

@MainActor
final class WritingStyleAutoUpdater: ObservableObject {
  static let shared = WritingStyleAutoUpdater()

  @Published private(set) var isWorking = false
  /// User-facing, short, e.g. "Imported 42 new emails."
  @Published private(set) var lastMessage: String?

  static let profileThreshold = 20
  static let gmailInterval: TimeInterval = 7 * 24 * 3600
  private static let dailyCheckInterval: TimeInterval = 24 * 3600

  private var dailyTimer: Timer?

  private init() {}

  /// Under XCTest the process shares the dev app's defaults, where Writing Style may be on: a run
  /// would import Gmail, call the model with real messages and show the review panel.
  private static func skipUnderTest() -> Bool {
    guard isRunningUnderTest else { return false }
    DebugLogger.log("WRITING-STYLE-AUTO: skipped under test")
    return true
  }

  /// Runs `runIfDue()` now and then once a day while the app stays open. Call once after launch.
  /// Safe to call again: only one timer is ever active. Not in a sidecar, which shares the user's
  /// data directory and must not import Gmail or offer a profile a second time.
  ///
  /// Used to be started by the Smart Improvement auto-run coordinator, which ran it before its
  /// own job; that coordinator is gone (owner decision 2026-11-02), so Writing Style owns its timer.
  func startDailySchedule() {
    guard !AppConstants.isSidecarInstance, dailyTimer == nil else { return }
    // Detached from the caller: the profile review panel can wait on the user indefinitely.
    Task { @MainActor in await self.runIfDue() }
    dailyTimer = Timer.scheduledTimer(withTimeInterval: Self.dailyCheckInterval, repeats: true) { _ in
      Task { @MainActor in await WritingStyleAutoUpdater.shared.runIfDue() }
    }
    DebugLogger.log("WRITING-STYLE-AUTO: daily check timer started")
  }

  private var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: UserDefaultsKeys.writingStyleEnabled)
  }

  private var gmailConnected: Bool {
    get async { await GoogleAccountOAuthService.shared.isConnected }
  }

  private var improvementModelHasCredential: Bool {
    PromptModel.loadChatSlotModel(
      forKey: UserDefaultsKeys.selectedImprovementModel,
      default: SettingsDefaults.selectedImprovementModel
    ).provider.hasCredential
  }

  // MARK: - Automatic

  /// Toggle just turned on: import Gmail now (if connected and not offline), then derive the
  /// profile if any samples exist.
  func handleEnabled() async {
    guard !Self.skipUnderTest(), !isWorking, isEnabled, !OfflineMode.isEnabled else { return }
    isWorking = true
    defer { isWorking = false }
    DebugLogger.log("WRITING-STYLE-AUTO: enabled, starting")

    if await gmailConnected {
      do {
        let result = try await WritingStyleImporter.importFromGmail()
        lastMessage = result.summary
        DebugLogger.log("WRITING-STYLE-AUTO: gmail import added=\(result.added) failed=\(result.failedThreads)")
      } catch {
        lastMessage = error.localizedDescription
        DebugLogger.logError("WRITING-STYLE-AUTO: gmail import failed")
      }
    }

    guard !WritingStyleStore.shared.loadSamples().isEmpty, improvementModelHasCredential else { return }
    await derive(userTriggered: false)
  }

  /// Pure due rule. A first profile is offered once enough samples exist, but not again after the
  /// user dismissed the review; 20 NEW samples re-offer it either way.
  nonisolated static func isProfileDue(since: Int, total: Int, hasProfile: Bool, dismissed: Bool) -> Bool {
    since >= profileThreshold || (!hasProfile && !dismissed && total >= profileThreshold)
  }

  /// Daily check (launch + 24h timer).
  func runIfDue() async {
    guard !Self.skipUnderTest(), !isWorking, isEnabled, !OfflineMode.isEnabled else { return }
    isWorking = true
    defer { isWorking = false }

    let store = WritingStyleStore.shared

    if await gmailConnected {
      let last = UserDefaults.standard.object(forKey: UserDefaultsKeys.writingStyleLastGmailImportAt) as? Date
      if last == nil || Date().timeIntervalSince(last!) >= Self.gmailInterval {
        do {
          let result = try await WritingStyleImporter.importFromGmail()
          lastMessage = result.summary
          DebugLogger.log("WRITING-STYLE-AUTO: gmail import added=\(result.added) failed=\(result.failedThreads)")
        } catch {
          DebugLogger.logError("WRITING-STYLE-AUTO: gmail import failed")
        }
      }
    }

    let since = store.samplesSinceProfile
    let total = store.loadSamples().count
    let dismissed = UserDefaults.standard.object(forKey: UserDefaultsKeys.writingStyleProfileDismissedAt) != nil
    let due = Self.isProfileDue(
      since: since, total: total, hasProfile: store.hasProfile, dismissed: dismissed)
    DebugLogger.log("WRITING-STYLE-AUTO: check since=\(since) total=\(total) due=\(due)")
    guard due, improvementModelHasCredential else { return }
    await derive(userTriggered: false)
  }

  // MARK: - Settings buttons

  /// Gmail import + derive, like the old Settings button.
  func importNow() async {
    guard !Self.skipUnderTest(), !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let result = try await WritingStyleImporter.importFromGmail()
      lastMessage = result.summary
      DebugLogger.log("WRITING-STYLE-AUTO: manual import added=\(result.added) failed=\(result.failedThreads)")
    } catch {
      lastMessage = error.localizedDescription
      DebugLogger.logError("WRITING-STYLE-AUTO: manual import failed")
      return
    }
    await derive(userTriggered: true)
  }

  func updateProfileNow() async {
    guard !Self.skipUnderTest(), !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    await derive(userTriggered: true)
  }

  // MARK: - Helpers

  private func derive(userTriggered: Bool) async {
    guard !Self.skipUnderTest() else { return }
    do {
      let saved = try await WritingStyleImporter.deriveProfile()
      DebugLogger.log("WRITING-STYLE-AUTO: derive saved=\(saved != nil)")
      if userTriggered {
        lastMessage = saved != nil ? String(localized: "Style profile updated.") : String(localized: "Profile update cancelled.")
      } else if saved != nil {
        lastMessage = String(localized: "Style profile updated.")
      }
    } catch {
      DebugLogger.logError("WRITING-STYLE-AUTO: derive failed")
      if userTriggered { lastMessage = error.localizedDescription }
    }
  }
}
