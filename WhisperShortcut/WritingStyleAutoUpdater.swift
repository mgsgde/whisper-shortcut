//
//  WritingStyleAutoUpdater.swift
//  WhisperShortcut
//
//  Keeps Writing Style learning on its own while the toggle is on: imports sent emails from Gmail
//  weekly and re-derives the profile once enough new samples have arrived. The profile review
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

  private init() {}

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
    guard !isWorking, isEnabled, !OfflineMode.isEnabled else { return }
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

  /// Daily check (launch + 24h timer).
  func runIfDue() async {
    guard !isWorking, isEnabled, !OfflineMode.isEnabled else { return }
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
    let due = since >= Self.profileThreshold
      || (store.profileUpdatedAt == nil && total >= Self.profileThreshold)
    DebugLogger.log("WRITING-STYLE-AUTO: check since=\(since) total=\(total) due=\(due)")
    guard due, improvementModelHasCredential else { return }
    await derive(userTriggered: false)
  }

  // MARK: - Settings buttons

  /// Gmail import + derive, like the old Settings button.
  func importNow() async {
    guard !isWorking else { return }
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
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    await derive(userTriggered: true)
  }

  // MARK: - Helpers

  private func derive(userTriggered: Bool) async {
    do {
      let saved = try await WritingStyleImporter.deriveProfile()
      DebugLogger.log("WRITING-STYLE-AUTO: derive saved=\(saved != nil)")
      if userTriggered {
        lastMessage = saved != nil ? "Style profile updated." : "Profile update cancelled."
      } else if saved != nil {
        lastMessage = "Style profile updated."
      }
    } catch {
      DebugLogger.logError("WRITING-STYLE-AUTO: derive failed")
      if userTriggered { lastMessage = error.localizedDescription }
    }
  }
}
