//
//  WritingStyleAutoUpdater.swift
//  WhisperShortcut
//
//  Keeps Writing Style learning on its own while the toggle is on: imports sent emails from Gmail
//  weekly and stores a profile suggestion as a pending proposal once enough new samples have
//  arrived. A check the app runs on its own only waits in the menu; one the user asked for opens
//  the review window. Logs carry counts only, never text.
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
  /// Minimum time between profile proposals the app makes on its own.
  static let proposalCooldown: TimeInterval = 14 * 24 * 3600
  private static let dailyCheckInterval: TimeInterval = 24 * 3600

  private var dailyTimer: Timer?

  private init() {}

  /// Under XCTest the process shares the dev app's defaults, where Writing Style may be on: a run
  /// would import Gmail and call the model with real messages.
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
    // Detached from the caller so a Gmail import does not block launch.
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
  /// profile if any samples exist. The user just asked, so the review window opens.
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
    await derive(userTriggered: true)
  }

  /// Pure due rule for automatic checks. A first profile is offered once enough samples exist, but
  /// not again after the user dismissed the review; it ignores the cooldown. An update needs 20 NEW
  /// samples and at least `proposalCooldown` since the last proposal. User-started paths skip this.
  nonisolated static func isProfileDue(
    since: Int, total: Int, hasProfile: Bool, dismissed: Bool, lastProposedAt: Date?, now: Date
  ) -> Bool {
    if !hasProfile && !dismissed && total >= profileThreshold { return true }
    guard since >= profileThreshold else { return false }
    guard let lastProposedAt else { return true }
    return now.timeIntervalSince(lastProposedAt) >= proposalCooldown
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
    let now = Date()
    let lastProposedAt = store.lastProposedAt
    let due = Self.isProfileDue(
      since: since, total: total, hasProfile: store.hasProfile, dismissed: dismissed,
      lastProposedAt: lastProposedAt, now: now)
    let cooldownDays = lastProposedAt.map {
      max(0, Int(ceil((Self.proposalCooldown - now.timeIntervalSince($0)) / 86_400)))
    } ?? 0
    DebugLogger.log(
      "WRITING-STYLE-AUTO: check since=\(since) total=\(total) due=\(due) cooldown=\(cooldownDays)")
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
      switch try await WritingStyleImporter.deriveProfile() {
      case .proposed(let proposal):
        DebugLogger.log("WRITING-STYLE-AUTO: derive proposed=1")
        if userTriggered {
          MCPProposalWindows.shared.show(proposal)
          lastMessage = String(localized: "Suggestion ready to review.")
        }
      case .unchanged:
        DebugLogger.log("WRITING-STYLE-AUTO: derive proposed=0")
        if userTriggered {
          lastMessage = String(localized: "No changes. Your profile already matches your messages.")
        }
      }
    } catch {
      DebugLogger.logError("WRITING-STYLE-AUTO: derive failed")
      if userTriggered { lastMessage = error.localizedDescription }
    }
  }
}
