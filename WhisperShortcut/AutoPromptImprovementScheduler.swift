import Foundation

/// Service that automatically runs system prompt improvements at configured intervals.
@MainActor
class AutoPromptImprovementScheduler {
  static let shared = AutoPromptImprovementScheduler()

  private init() {}

  /// Increments the successful-dictation counter and triggers an improvement run
  /// when the threshold is reached AND the cooldown interval has passed.
  /// Called after every successful transcription.
  func incrementDictationCountAndRunIfNeeded() {
    let interval = getCurrentInterval()
    guard interval != .never else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skip - disabled (Never)")
      return
    }
    guard GeminiCredentialProvider.shared.hasCredential() else {
      DebugLogger.log("AUTO-IMPROVEMENT: Skip - no Gemini credential")
      return
    }
    // First run ever: only require N dictations and any interaction data (no 7-day minimum, cooldown N/A).
    // Subsequent runs: when interval != .always, require 7+ days of usage and cooldown.
    let isFirstRun = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastAutoImprovementRunDate) as? Date == nil
    let minDays: Int = {
      if isFirstRun { return 0 }
      return interval == .always ? 0 : AppConstants.autoImprovementMinimumInteractionDays
    }()
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

  /// Runs the improvement pipeline immediately (manual trigger from Settings).
  /// Ignores cooldown, interval, and dictation count. Requires API key and at least some interaction data.
  func runImprovementNow() async {
    guard !isImprovementRunning else {
      PopupNotificationWindow.showInfo(
        "An improvement run is already in progress.",
        title: "Smart Improvement"
      )
      return
    }
    guard GeminiCredentialProvider.shared.hasCredential() else {
      PopupNotificationWindow.showError(
        "Add an API key in the General tab to use Smart Improvement.",
        title: "Smart Improvement"
      )
      return
    }
    guard UserContextLogger.shared.hasInteractionDataAtLeast(daysOld: 0) else {
      PopupNotificationWindow.showInfo(
        "No interaction data yet. Use dictation or prompt mode first.",
        title: "Smart Improvement"
      )
      return
    }
    isImprovementRunning = true
    defer { isImprovementRunning = false }
    DebugLogger.log("AUTO-IMPROVEMENT: Manual run started")
    PopupNotificationWindow.showInfo(
      "Smart Improvement started. You can switch tabs; we'll notify you when it's done.",
      title: "Smart Improvement"
    )
    await runImprovement()
    DebugLogger.log("AUTO-IMPROVEMENT: Manual run finished")
  }

  /// True while an improvement run (manual or automatic) is in progress. Use to show "Running…" when the user returns to the Smart Improvement section.
  var isRunning: Bool { isImprovementRunning }

  // MARK: - Private

  private var isImprovementRunning = false

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

  /// Current Smart Improvement model display name (e.g. "Gemini 3.1 Pro"). Same source as UserContextDerivation.
  private func currentImprovementModelDisplayName() -> String? {
    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedImprovementModel)
      ?? SettingsDefaults.selectedImprovementModel.rawValue
    guard let model = PromptModel(rawValue: raw) else { return nil }
    return model.displayName
  }

  private func runImprovement() async {
    let derivation = UserContextDerivation()
    var pendingKinds: [GenerationKind] = []

    // Run derivation for each focus
    let focuses: [GenerationKind] = [.userContext, .dictation, .promptMode, .promptAndRead]

    for focus in focuses {
      do {
        DebugLogger.log("AUTO-IMPROVEMENT: Running derivation for \(focus)")
        try await derivation.updateFromLogs(focus: focus)

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

    // Apply generated suggestions directly (no compare sheet)
    if !pendingKinds.isEmpty {
      DebugLogger.logSuccess("AUTO-IMPROVEMENT: Generated \(pendingKinds.count) suggestions — auto-applying")

      var appliedKinds: [GenerationKind] = []
      for kind in pendingKinds {
        if let suggested = readSuggestion(for: kind), !suggested.isEmpty {
          applySuggestion(suggested, for: kind)
          appliedKinds.append(kind)
          DebugLogger.logSuccess("AUTO-IMPROVEMENT: Auto-applied \(kind)")
        }
      }

      if !appliedKinds.isEmpty {
        let kindNames = appliedKinds.map { kind -> String in
          switch kind {
          case .userContext: return "User Context"
          case .dictation: return "Dictation Prompt"
          case .promptMode: return "Dictate Prompt System Prompt"
          case .promptAndRead: return "Prompt & Read System Prompt"
          }
        }
        DebugLogger.logSuccess("AUTO-IMPROVEMENT: Applied: \(kindNames.joined(separator: ", "))")
        let message = "Auto-improved: \(kindNames.joined(separator: ", ")). Check Settings to review or revert."
        await MainActor.run {
          PopupNotificationWindow.showInfo(message, title: "Smart Improvement")
        }
      }
    } else {
      DebugLogger.log("AUTO-IMPROVEMENT: No suggestions generated")
      await MainActor.run {
        PopupNotificationWindow.showInfo(
          "Auto-improvement ran but no suggestions could be generated (e.g. API busy). It will run again after more dictations.",
          title: "Smart Improvement"
        )
      }
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
    let improvementModel = currentImprovementModelDisplayName()
    switch kind {
    case .dictation:
      let currentDictation = UserDefaults.standard.string(forKey: UserDefaultsKeys.customPromptText) ?? AppConstants.defaultTranscriptionSystemPrompt
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.customPromptText)
      UserContextLogger.shared.deleteSuggestedDictationPromptFile()
      logSystemPromptChange(kind: "Dictation Prompt", previous: currentDictation, applied: suggested)
      UserContextLogger.shared.appendSystemPromptHistory(historyFileSuffix: "dictation", previousLength: currentDictation.count, newLength: suggested.count, content: suggested, model: improvementModel)

    case .promptMode:
      let currentPromptMode = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptModeSystemPrompt) ?? ""
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.promptModeSystemPrompt)
      UserContextLogger.shared.deleteSuggestedSystemPromptFile()
      logSystemPromptChange(kind: "Dictate Prompt", previous: currentPromptMode, applied: suggested)
      UserContextLogger.shared.appendSystemPromptHistory(historyFileSuffix: "prompt-mode", previousLength: currentPromptMode.count, newLength: suggested.count, content: suggested, model: improvementModel)

    case .promptAndRead:
      let currentPromptAndRead = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptAndReadSystemPrompt) ?? ""
      UserDefaults.standard.set(suggested, forKey: UserDefaultsKeys.promptAndReadSystemPrompt)
      UserContextLogger.shared.deleteSuggestedPromptAndReadSystemPromptFile()
      logSystemPromptChange(kind: "Prompt & Read", previous: currentPromptAndRead, applied: suggested)
      UserContextLogger.shared.appendSystemPromptHistory(historyFileSuffix: "prompt-and-read", previousLength: currentPromptAndRead.count, newLength: suggested.count, content: suggested, model: improvementModel)

    case .userContext:
      let contextDir = UserContextLogger.shared.directoryURL
      let fileURL = contextDir.appendingPathComponent("user-context.md")
      let currentUserContext = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
      try? suggested.write(to: fileURL, atomically: true, encoding: .utf8)
      NotificationCenter.default.post(name: .userContextFileDidUpdate, object: nil)
      UserContextLogger.shared.deleteSuggestedUserContextFile()
      UserContextLogger.shared.appendUserContextHistory(previousLength: currentUserContext.count, newLength: suggested.count, content: suggested, model: improvementModel)
    }
  }

  private func logSystemPromptChange(kind: String, previous: String, applied: String) {
    let prevLen = previous.count
    let newLen = applied.count
    let firstLineBefore = previous.split(separator: "\n").first.map(String.init) ?? ""
    let firstLineAfter = applied.split(separator: "\n").first.map(String.init) ?? ""
    let beforePreview = firstLineBefore.count > 80 ? String(firstLineBefore.prefix(80)) + "…" : firstLineBefore
    let afterPreview = firstLineAfter.count > 80 ? String(firstLineAfter.prefix(80)) + "…" : firstLineAfter
    DebugLogger.log("SYSTEM-PROMPT-CHANGE: \(kind) (source=auto) — previous \(prevLen) chars, new \(newLen) chars. First line before: \"\(beforePreview)\" first line after: \"\(afterPreview)\"")
  }
}

