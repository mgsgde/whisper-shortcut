import Foundation

/// Notification name for when auto-improvement suggestions are ready
extension Notification.Name {
  static let autoImprovementSuggestionsReady = Notification.Name("autoImprovementSuggestionsReady")
}

/// Service that automatically runs system prompt improvements at configured intervals.
@MainActor
class AutoPromptImprovementScheduler {
  static let shared = AutoPromptImprovementScheduler()

  private init() {}

  /// Checks if it's time to run auto-improvement and triggers it if needed.
  /// Should be called on app launch and periodically during app usage.
  func checkAndRunIfNeeded() {
    guard shouldRun() else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skipping - conditions not met")
      return
    }

    DebugLogger.log("AUTO-IMPROVEMENT: Starting automatic improvement run")
    Task {
      await runImprovement()
    }
  }

  /// Checks if there are pending suggestions from a previous run (e.g., app was closed during generation).
  /// Should be called on app launch to show pending suggestions.
  func checkForPendingSuggestions() -> Bool {
    let pendingKinds = loadPendingKinds()
    return !pendingKinds.isEmpty
  }

  /// Loads pending improvement kinds from persistent storage.
  func loadPendingKinds() -> [GenerationKind] {
    guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.pendingAutoImprovementKinds),
          let kinds = try? JSONDecoder().decode([GenerationKind].self, from: data) else {
      return []
    }
    return kinds
  }

  /// Clears pending improvement kinds from storage.
  func clearPendingKinds() {
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.pendingAutoImprovementKinds)
    DebugLogger.log("AUTO-IMPROVEMENT: Cleared pending kinds")
  }

  // MARK: - Private

  private func shouldRun() -> Bool {
    // Check if auto-improvement is enabled (not "Never")
    let interval = getCurrentInterval()
    guard interval != .never else {
      DebugLogger.log("AUTO-IMPROVEMENT: Disabled (interval is Never)")
      return false
    }

    // Check if logging is enabled
    guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.userContextLoggingEnabled) else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skipping - logging disabled")
      return false
    }

    // Check if API key exists
    guard KeychainManager.shared.hasGoogleAPIKey() else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skipping - no API key")
      return false
    }

    // Check if enough time has passed since last run
    guard hasEnoughTimePassed(interval: interval) else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skipping - not enough time passed")
      return false
    }

    // Check if there are interaction logs (at least some data to analyze)
    let logFiles = UserContextLogger.shared.interactionLogFiles(lastDays: 30)
    guard !logFiles.isEmpty else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skipping - no interaction logs found")
      return false
    }

    // Only show suggestions after the user has at least N days of interaction data (e.g. 7 days)
    let minDays = AppConstants.autoImprovementMinimumInteractionDays
    guard UserContextLogger.shared.hasInteractionDataAtLeast(daysOld: minDays) else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skipping - need at least \(minDays) days of interaction data before showing suggestions")
      return false
    }

    return true
  }

  private func getCurrentInterval() -> AutoImprovementInterval {
    let rawValue = UserDefaults.standard.integer(forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays)
    return AutoImprovementInterval(rawValue: rawValue) ?? .default
  }

  private func hasEnoughTimePassed(interval: AutoImprovementInterval) -> Bool {
    guard let lastRunDate = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastAutoImprovementRunDate) as? Date else {
      // No previous run - allow first run immediately (or wait for first interval period)
      // For first run, we'll allow it after the interval period has passed from app install/first use
      return true
    }

    let daysSinceLastRun = Calendar.current.dateComponents([.day], from: lastRunDate, to: Date()).day ?? 0
    return daysSinceLastRun >= interval.days
  }

  private func runImprovement() async {
    let derivation = UserContextDerivation()
    var pendingKinds: [GenerationKind] = []

    // Run derivation for each focus
    let focuses: [GenerationKind] = [.userContext, .dictation, .promptMode, .promptAndRead]

    for focus in focuses {
      do {
        DebugLogger.log("AUTO-IMPROVEMENT: Running derivation for \(focus)")
        _ = try await derivation.updateFromLogs(focus: focus)

        // Check if a suggestion was generated
        if hasSuggestion(for: focus) {
          pendingKinds.append(focus)
          DebugLogger.log("AUTO-IMPROVEMENT: Found suggestion for \(focus)")
        } else {
          DebugLogger.log("AUTO-IMPROVEMENT: No suggestion generated for \(focus)")
        }
      } catch {
        DebugLogger.logError("AUTO-IMPROVEMENT: Failed to generate suggestion for \(focus): \(error.localizedDescription)")
        // Continue with other focuses even if one fails
      }
    }

    // Save pending kinds and update last run date
    if !pendingKinds.isEmpty {
      savePendingKinds(pendingKinds)
      DebugLogger.logSuccess("AUTO-IMPROVEMENT: Generated \(pendingKinds.count) suggestions")
      
      // Open Settings and notify
      await MainActor.run {
        SettingsManager.shared.showSettings()
        NotificationCenter.default.post(name: .autoImprovementSuggestionsReady, object: nil)
      }
    } else {
      DebugLogger.log("AUTO-IMPROVEMENT: No suggestions generated")
    }

    // Update last run date regardless of whether suggestions were generated
    UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastAutoImprovementRunDate)
  }

  private func hasSuggestion(for kind: GenerationKind) -> Bool {
    let contextDir = UserContextLogger.shared.directoryURL
    let fileURL: URL

    switch kind {
    case .userContext:
      fileURL = contextDir.appendingPathComponent("suggested-user-context.md")
    case .dictation:
      fileURL = contextDir.appendingPathComponent("suggested-dictation-prompt.txt")
    case .promptMode:
      fileURL = contextDir.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
    case .promptAndRead:
      fileURL = contextDir.appendingPathComponent("suggested-prompt-and-read-system-prompt.txt")
    }

    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return false
    }

    return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func savePendingKinds(_ kinds: [GenerationKind]) {
    if let data = try? JSONEncoder().encode(kinds) {
      UserDefaults.standard.set(data, forKey: UserDefaultsKeys.pendingAutoImprovementKinds)
      DebugLogger.log("AUTO-IMPROVEMENT: Saved \(kinds.count) pending kinds")
    }
  }
}

