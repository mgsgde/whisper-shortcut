import AppKit
import Foundation

/// Service that automatically runs system prompt improvements at configured intervals.
@MainActor
class AutoPromptImprovementScheduler {
  static let shared = AutoPromptImprovementScheduler()

  private init() {}

  /// No-op: automatic improvement was removed; improvement runs only when the user triggers "Improve from usage" or "Improve from voice".
  func incrementDictationCountAndRunIfNeeded() {}

  /// Runs the improvement pipeline immediately (manual trigger from Settings or auto-run).
  /// Ignores cooldown and interval. Requires credential and at least some interaction data.
  /// If a run is already in progress, enqueues this job and notifies the user.
  /// - Parameter fromAutoRun: When true (e.g. launch/daily timer), no popup is shown when there is no interaction data; when false (user tapped "Improve from usage"), show error.
  func runImprovementNow(fromAutoRun: Bool = false) async {
    guard GeminiCredentialProvider.shared.hasCredential() else { return }

    // Total-data gate: require enough overall interactions before running anything.
    let counts = ContextLogger.shared.interactionCountsByMode(lastDays: AppConstants.smartImprovementEligibilityDays)
    let totalInteractions = counts.values.reduce(0, +)
    if totalInteractions < AppConstants.smartImprovementMinTotalInteractions {
      if !fromAutoRun {
        PopupNotificationWindow.showError(
          "Not enough usage data yet (\(totalInteractions)/\(AppConstants.smartImprovementMinTotalInteractions)). Use dictation or prompt mode a bit more, then try again.",
          title: "Smart Improvement"
        )
      }
      return
    }

    // Cooldown gate: throttle manual triggers.
    if !fromAutoRun, let last = lastRunStartedAt {
      let elapsed = Date().timeIntervalSince(last)
      if elapsed < AppConstants.smartImprovementCooldownSeconds {
        let remaining = Int(ceil(AppConstants.smartImprovementCooldownSeconds - elapsed))
        PopupNotificationWindow.showInfo(
          "Smart Improvement is on cooldown. Try again in \(remaining)s.",
          title: "Smart Improvement"
        )
        return
      }
    }

    if isImprovementRunning {
      if improvementQueue.count >= AppConstants.smartImprovementMaxQueuedJobs {
        PopupNotificationWindow.showInfo(
          "A run is already in progress and the queue is full. Try again later.",
          title: "Smart Improvement"
        )
        return
      }
      improvementQueue.append(.fromUsage)
      showQueuedMessage()
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
    await processNextInQueue()
  }

  /// True while an improvement run (manual or automatic) is in progress. Use to show "Running…" when the user returns to the Smart Improvement section.
  var isRunning: Bool { isImprovementRunning }

  /// Number of improvement jobs waiting in the queue (0 when none).
  var queuedJobCount: Int { improvementQueue.count }

  // MARK: - Private

  private enum ImprovementJob {
    case fromUsage
  }

  private var isImprovementRunning = false
  private var improvementQueue: [ImprovementJob] = []
  /// Wall-clock time of the last run start (for cooldown check). nil = never run this session.
  private var lastRunStartedAt: Date?

  private func showQueuedMessage() {
    let n = improvementQueue.count
    let message = n == 1
      ? "Added to queue. 1 improvement queued."
      : "Added to queue. \(n) improvements queued."
    PopupNotificationWindow.showInfo(message, title: "Smart Improvement")
  }

  /// Runs the next job in the queue if any. Call after the current run finishes. Does not set isImprovementRunning; caller must set/clear it for the job being run.
  private func processNextInQueue() async {
    guard let job = improvementQueue.first else { return }
    improvementQueue.removeFirst()
    isImprovementRunning = true
    defer { isImprovementRunning = false }
    switch job {
    case .fromUsage:
      DebugLogger.log("AUTO-IMPROVEMENT: Processing queued from-usage job")
      PopupNotificationWindow.showInfo(
        "Smart Improvement started. You can switch tabs; we'll notify you when it's done.",
        title: "Smart Improvement"
      )
      await runImprovement()
      DebugLogger.log("AUTO-IMPROVEMENT: Queued from-usage job finished")
    }
    await processNextInQueue()
  }

  /// Current Smart Improvement model display name (e.g. "Gemini 3 Flash"). Same source as ContextDerivation.
  private func currentImprovementModelDisplayName() -> String? {
    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedImprovementModel)
      ?? SettingsDefaults.selectedImprovementModel.rawValue
    let migratedRaw = PromptModel.migrateLegacyPromptRawValue(raw)
    guard let model = PromptModel(rawValue: migratedRaw) else { return nil }
    return model.displayName
  }

  /// Maps each focus to the interaction `mode` field that counts as its primary signal. Mirrors ContextDerivation.primaryMode.
  /// `geminiChat` has no single primary mode and uses the total interaction count instead.
  private func primaryModeKey(for focus: GenerationKind) -> String? {
    switch focus {
    case .dictation, .whisperGlossary: return "transcription"
    case .promptMode: return "prompt"
    case .promptAndRead: return "promptAndRead"
    case .geminiChat: return nil
    }
  }

  private func runImprovement() async {
    lastRunStartedAt = Date()
    // Discard any stale suggestion files from a previously crashed/aborted run before generating new ones.
    ContextLogger.shared.deleteAllSuggestedFiles()

    let derivation = ContextDerivation()
    let allFocuses: [GenerationKind] = [.dictation, .whisperGlossary, .promptMode, .promptAndRead, .geminiChat]

    // Per-focus eligibility: skip focuses without enough primary-mode data in the lookback window.
    let counts = ContextLogger.shared.interactionCountsByMode(lastDays: AppConstants.smartImprovementEligibilityDays)
    let total = counts.values.reduce(0, +)
    let minPerFocus = AppConstants.smartImprovementMinPerFocusInteractions
    let focuses: [GenerationKind] = allFocuses.filter { focus in
      if let mode = primaryModeKey(for: focus) {
        let n = counts[mode] ?? 0
        if n < minPerFocus {
          DebugLogger.log("AUTO-IMPROVEMENT: Skipping \(focus) — only \(n) entries for mode \(mode) (need \(minPerFocus))")
          return false
        }
      } else {
        // geminiChat: gate on total instead of a single mode.
        if total < minPerFocus {
          DebugLogger.log("AUTO-IMPROVEMENT: Skipping \(focus) — only \(total) total entries (need \(minPerFocus))")
          return false
        }
      }
      return true
    }

    if focuses.isEmpty {
      DebugLogger.log("AUTO-IMPROVEMENT: No focuses eligible — skipping run")
      await MainActor.run {
        PopupNotificationWindow.showInfo(
          "Not enough per-mode usage yet. Use the app a bit more and try again.",
          title: "Smart Improvement"
        )
      }
      UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastAutoImprovementRunDate)
      return
    }

    typealias FocusResult = (focus: GenerationKind, error: Error?)
    let results: [FocusResult] = await withTaskGroup(of: FocusResult.self) { group in
      for focus in focuses {
        group.addTask {
          do {
            DebugLogger.log("AUTO-IMPROVEMENT: Running derivation for \(focus)")
            try await derivation.updateFromLogs(focus: focus)
            return (focus, nil as Error?)
          } catch {
            return (focus, error)
          }
        }
      }
      var collected: [FocusResult] = []
      for await result in group { collected.append(result) }
      return collected
    }

    let failedErrors = results.compactMap { $0.error }
    var pendingKinds: [GenerationKind] = []
    for (focus, error) in results {
      if let error = error {
        DebugLogger.logError("AUTO-IMPROVEMENT: Failed to generate suggestion for \(focus): \(error.localizedDescription)")
        continue
      }
      if hasSuggestion(for: focus) {
        pendingKinds.append(focus)
        DebugLogger.log("AUTO-IMPROVEMENT: Found suggestion for \(focus)")
      } else {
        DebugLogger.log("AUTO-IMPROVEMENT: No suggestion generated for \(focus)")
      }
    }

    // Stable order for review UI (dictation, promptMode, promptAndRead, geminiChat)
    pendingKinds.sort { a, b in
      (focuses.firstIndex(of: a) ?? 0) < (focuses.firstIndex(of: b) ?? 0)
    }

    // Present review UI for each suggestion; apply only on Accept, discard on Cancel
    if !pendingKinds.isEmpty {
      DebugLogger.logSuccess("AUTO-IMPROVEMENT: Generated \(pendingKinds.count) suggestions — showing review")
      let total = pendingKinds.count
      var appliedKinds: [GenerationKind] = []
      for (index, kind) in pendingKinds.enumerated() {
        guard let suggested = readSuggestion(for: kind), !suggested.isEmpty else { continue }
        let original = currentContent(for: kind)
        let rationale = readRationale(for: kind)
        let oneBased = index + 1
        let result = await SmartImprovementReviewPanel.present(
          focusDisplayName: kind.improvementDisplayName,
          index: total > 1 ? oneBased : nil,
          total: total > 1 ? total : nil,
          originalText: original,
          suggestedText: suggested,
          rationale: rationale
        )
        if let accepted = result, !accepted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          applySuggestion(accepted, for: kind)
          appliedKinds.append(kind)
          DebugLogger.logSuccess("AUTO-IMPROVEMENT: Applied \(kind) from review")
        } else {
          discardSuggestion(for: kind)
          DebugLogger.log("AUTO-IMPROVEMENT: User cancelled or empty for \(kind)")
        }
      }
      if !appliedKinds.isEmpty {
        let kindNames = appliedKinds.map(\.improvementDisplayName)
        DebugLogger.logSuccess("AUTO-IMPROVEMENT: Applied: \(kindNames.joined(separator: ", "))")
        let message = "System prompts updated: \(kindNames.joined(separator: ", ")). Check Settings to review or revert."
        await MainActor.run {
          PopupNotificationWindow.showInfo(message, title: "Smart Improvement")
        }
      } else {
        await MainActor.run {
          PopupNotificationWindow.showInfo(
            "No changes applied. You cancelled all suggestions or left them empty.",
            title: "Smart Improvement"
          )
        }
      }
    } else {
      DebugLogger.log("AUTO-IMPROVEMENT: No suggestions generated")
      await MainActor.run {
        if let firstError = failedErrors.first {
          PopupNotificationWindow.showError(
            SpeechErrorFormatter.formatForUser(firstError),
            title: "Smart Improvement"
          )
        } else {
          PopupNotificationWindow.showInfo(
            "No suggestions could be generated. Try again later or check that you have interaction data.",
            title: "Smart Improvement"
          )
        }
      }
    }

    // Update last run date regardless of whether suggestions were generated
    UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastAutoImprovementRunDate)
  }

  private func hasSuggestion(for kind: GenerationKind) -> Bool {
    let contextDir = ContextLogger.shared.directoryURL
    let fileURL: URL

    switch kind {
    case .dictation:
      fileURL = contextDir.appendingPathComponent("suggested-dictation-prompt.txt")
    case .whisperGlossary:
      fileURL = contextDir.appendingPathComponent("suggested-whisper-glossary.txt")
    case .promptMode:
      fileURL = contextDir.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
    case .promptAndRead:
      fileURL = contextDir.appendingPathComponent("suggested-prompt-read-mode-system-prompt.txt")
    case .geminiChat:
      fileURL = contextDir.appendingPathComponent("suggested-gemini-chat-system-prompt.txt")
    }

    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return false
    }

    return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Returns the current stored content for the given focus (after apply). Used to build clipboard output for improved sections only.
  private func currentContent(for kind: GenerationKind) -> String {
    let store = SystemPromptsStore.shared
    switch kind {
    case .dictation: return store.loadDictationPrompt()
    case .whisperGlossary: return store.loadWhisperGlossary()
    case .promptMode: return store.loadDictatePromptSystemPrompt()
    case .promptAndRead: return store.loadPromptAndReadSystemPrompt()
    case .geminiChat: return store.loadSection(.geminiChat) ?? ""
    }
  }

  private func readSuggestion(for kind: GenerationKind) -> String? {
    let contextDir = ContextLogger.shared.directoryURL
    let fileURL: URL

    switch kind {
    case .dictation:
      fileURL = contextDir.appendingPathComponent("suggested-dictation-prompt.txt")
    case .whisperGlossary:
      fileURL = contextDir.appendingPathComponent("suggested-whisper-glossary.txt")
    case .promptMode:
      fileURL = contextDir.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
    case .promptAndRead:
      fileURL = contextDir.appendingPathComponent("suggested-prompt-read-mode-system-prompt.txt")
    case .geminiChat:
      fileURL = contextDir.appendingPathComponent("suggested-gemini-chat-system-prompt.txt")
    }

    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return nil
    }

    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func readRationale(for kind: GenerationKind) -> String? {
    let baseName: String
    switch kind {
    case .dictation: baseName = "suggested-dictation-prompt"
    case .whisperGlossary: baseName = "suggested-whisper-glossary"
    case .promptMode: baseName = "suggested-prompt-mode-system-prompt"
    case .promptAndRead: baseName = "suggested-prompt-read-mode-system-prompt"
    case .geminiChat: baseName = "suggested-gemini-chat-system-prompt"
    }
    let url = ContextLogger.shared.directoryURL.appendingPathComponent(baseName + "-rationale.txt")
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Deletes the suggestion file for the given focus without applying. Use when the user cancels the review.
  private func discardSuggestion(for kind: GenerationKind) {
    switch kind {
    case .dictation: ContextLogger.shared.deleteSuggestedDictationPromptFile()
    case .whisperGlossary: ContextLogger.shared.deleteSuggestedWhisperGlossaryFile()
    case .promptMode: ContextLogger.shared.deleteSuggestedSystemPromptFile()
    case .promptAndRead: ContextLogger.shared.deleteSuggestedPromptAndReadSystemPromptFile()
    case .geminiChat: ContextLogger.shared.deleteSuggestedGeminiChatSystemPromptFile()
    }
    // Also remove rationale sidecar.
    let baseName: String
    switch kind {
    case .dictation: baseName = "suggested-dictation-prompt"
    case .whisperGlossary: baseName = "suggested-whisper-glossary"
    case .promptMode: baseName = "suggested-prompt-mode-system-prompt"
    case .promptAndRead: baseName = "suggested-prompt-read-mode-system-prompt"
    case .geminiChat: baseName = "suggested-gemini-chat-system-prompt"
    }
    let url = ContextLogger.shared.directoryURL.appendingPathComponent(baseName + "-rationale.txt")
    try? FileManager.default.removeItem(at: url)
  }

  private func applySuggestion(_ suggested: String, for kind: GenerationKind) {
    let improvementModel = currentImprovementModelDisplayName()
    let section = kind.systemPromptSection
    let currentContent = SystemPromptsStore.shared.loadSection(section) ?? ""
    let previousLength = currentContent.count
    SystemPromptsStore.shared.updateSection(section, content: suggested)
    ContextLogger.shared.appendSystemPromptsHistory(section: section, previousLength: previousLength, newLength: suggested.count, content: suggested, model: improvementModel)
    discardSuggestion(for: kind)
    let kindName = kind.improvementDisplayName
    logSystemPromptChange(kind: kindName, previous: currentContent, applied: suggested)
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

private extension GenerationKind {
  var systemPromptSection: SystemPromptSection {
    switch self {
    case .dictation: return .dictation
    case .whisperGlossary: return .whisperGlossary
    case .promptMode: return .promptMode
    case .promptAndRead: return .promptAndRead
    case .geminiChat: return .geminiChat
    }
  }
}

