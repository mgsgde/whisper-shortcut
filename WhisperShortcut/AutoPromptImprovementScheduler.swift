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

  /// Increments the successful-dictation counter and triggers an improvement run
  /// when the threshold is reached AND the cooldown interval has passed.
  /// Called after every successful transcription.
  func incrementDictationCountAndRunIfNeeded() {
    let interval = getCurrentInterval()
    guard interval != .never else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skip - disabled (Never)")
      return
    }
    guard KeychainManager.shared.hasGoogleAPIKey() else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skip - no API key")
      return
    }
    let minDays = AppConstants.autoImprovementMinimumInteractionDays
    guard UserContextLogger.shared.hasInteractionDataAtLeast(daysOld: minDays) else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skip - need at least \(minDays) days of data")
      return
    }

    // Increment counter
    let current = UserDefaults.standard.integer(forKey: UserDefaultsKeys.promptImprovementDictationCount) + 1
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.promptImprovementDictationCount)
    let threshold: Int = {
      let stored = UserDefaults.standard.integer(forKey: UserDefaultsKeys.promptImprovementDictationThreshold)
      return stored > 0 ? stored : AppConstants.promptImprovementDictationThreshold
    }()
    DebugLogger.log("AUTO-IMPROVEMENT: Dictation count = \(current)/\(threshold)")

    guard current >= threshold else { return }

    // Threshold reached — check cooldown
    guard hasEnoughTimePassed(interval: interval) else {
      DebugLogger.log("AUTO-IMPROVEMENT: Threshold reached but cooldown not passed yet — keeping count at \(current)")
      return
    }

    // Reset counter and run improvement
    UserDefaults.standard.set(0, forKey: UserDefaultsKeys.promptImprovementDictationCount)
    DebugLogger.log("AUTO-IMPROVEMENT: Threshold reached & cooldown passed — starting improvement run")
    Task {
      await runImprovement()
    }
  }

  // MARK: - Private

  private func getCurrentInterval() -> AutoImprovementInterval {
    let rawValue = UserDefaults.standard.integer(forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays)
    return AutoImprovementInterval(rawValue: rawValue) ?? .default
  }

  private func hasEnoughTimePassed(interval: AutoImprovementInterval) -> Bool {
    if interval == .always { return true }

    guard let lastRunDate = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastAutoImprovementRunDate) as? Date else {
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

    // Handle generated suggestions
    if !pendingKinds.isEmpty {
      let autoApply = UserDefaults.standard.object(forKey: UserDefaultsKeys.autoApplyImprovements) == nil
        ? true  // default to true if not set
        : UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoApplyImprovements)

      if autoApply {
        // Auto-apply mode: apply suggestions directly
        DebugLogger.logSuccess("AUTO-IMPROVEMENT: Generated \(pendingKinds.count) suggestions — auto-applying")

        var appliedKinds: [GenerationKind] = []
        for kind in pendingKinds {
          if let suggested = readSuggestion(for: kind), !suggested.isEmpty {
            applySuggestion(suggested, for: kind)
            appliedKinds.append(kind)
            DebugLogger.logSuccess("AUTO-IMPROVEMENT: Auto-applied \(kind)")
          }
        }

        clearPendingKinds()

        if !appliedKinds.isEmpty {
          await MainActor.run {
            let kindNames = appliedKinds.map { kind -> String in
              switch kind {
              case .userContext: return "User Context"
              case .dictation: return "Dictation Prompt"
              case .promptMode: return "Dictate Prompt System Prompt"
              case .promptAndRead: return "Prompt & Read System Prompt"
              }
            }
            let message = "Auto-improved: \(kindNames.joined(separator: ", ")). Check Settings to review or revert."
            PopupNotificationWindow.showTranscriptionResponse(message)
          }
        }
      } else {
        // Manual mode: save pending kinds and open Settings for review
        savePendingKinds(pendingKinds)
        DebugLogger.logSuccess("AUTO-IMPROVEMENT: Generated \(pendingKinds.count) suggestions — awaiting manual review")

        await MainActor.run {
          SettingsManager.shared.showSettings()
          NotificationCenter.default.post(name: .autoImprovementSuggestionsReady, object: nil)

          let kindNames = pendingKinds.map { kind -> String in
            switch kind {
            case .userContext: return "User Context"
            case .dictation: return "Dictation Prompt"
            case .promptMode: return "Dictate Prompt System Prompt"
            case .promptAndRead: return "Prompt & Read System Prompt"
            }
          }
          let message = "New suggestions for: \(kindNames.joined(separator: ", ")). Open Settings to review."
          PopupNotificationWindow.showTranscriptionResponse(message)
        }
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

  private func readSuggestion(for kind: GenerationKind) -> String? {
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
      return nil
    }

    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func applySuggestion(_ suggested: String, for kind: GenerationKind) {
    switch kind {
    case .dictation:
      let current = UserDefaults.standard.string(forKey: UserDefaultsKeys.customPromptText) ?? ""
      UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousCustomPromptText)
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasPreviousCustomPromptText)
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.lastAppliedCustomPromptText)
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasLastAppliedCustomPromptText)
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.customPromptText)
      UserContextLogger.shared.deleteSuggestedDictationPromptFile()

    case .promptMode:
      let current = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptModeSystemPrompt) ?? ""
      UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousPromptModeSystemPrompt)
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasPreviousPromptModeSystemPrompt)
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.lastAppliedPromptModeSystemPrompt)
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasLastAppliedPromptModeSystemPrompt)
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.promptModeSystemPrompt)
      UserContextLogger.shared.deleteSuggestedSystemPromptFile()

    case .promptAndRead:
      let current = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptAndReadSystemPrompt) ?? ""
      UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousPromptAndReadSystemPrompt)
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasPreviousPromptAndReadSystemPrompt)
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.lastAppliedPromptAndReadSystemPrompt)
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasLastAppliedPromptAndReadSystemPrompt)
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.promptAndReadSystemPrompt)
      UserContextLogger.shared.deleteSuggestedPromptAndReadSystemPromptFile()

    case .userContext:
      let contextDir = UserContextLogger.shared.directoryURL
      let fileURL = contextDir.appendingPathComponent("user-context.md")
      let current = (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousUserContext)
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasPreviousUserContext)
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.lastAppliedUserContext)
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasLastAppliedUserContext)
      try? suggested.write(to: fileURL, atomically: true, encoding: .utf8)
      NotificationCenter.default.post(name: .userContextFileDidUpdate, object: nil)
      UserContextLogger.shared.deleteSuggestedUserContextFile()
    }
  }
}

