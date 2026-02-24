import AppKit
import Foundation

/// Service that automatically runs system prompt improvements at configured intervals.
@MainActor
class AutoPromptImprovementScheduler {
  static let shared = AutoPromptImprovementScheduler()

  private init() {}

  /// No-op: automatic improvement was removed; improvement runs only when the user triggers "Improve from usage" or "Improve from voice".
  func incrementDictationCountAndRunIfNeeded() {}

  /// Runs the improvement pipeline immediately (manual trigger from Settings).
  /// Ignores cooldown and interval. Requires API key and at least some interaction data.
  /// If a run is already in progress, enqueues this job and notifies the user.
  func runImprovementNow() async {
    guard GeminiCredentialProvider.shared.hasCredential() else {
      PopupNotificationWindow.showError(
        "Add an API key in the General tab to use Smart Improvement.",
        title: "Smart Improvement"
      )
      return
    }
    guard ContextLogger.shared.hasInteractionDataAtLeast(daysOld: 0) else {
      PopupNotificationWindow.showInfo(
        "No interaction data yet. Use dictation or prompt mode first.",
        title: "Smart Improvement"
      )
      return
    }
    if isImprovementRunning {
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

  /// Runs improvement for all foci (Dictation, Dictate Prompt, Prompt & Read) using a transcribed voice instruction as the primary signal.
  /// Used by the "Improve from voice" shortcut / flow. Does not require interaction logs.
  /// When runInBackground is true, no persistent processing popup is shown; only auto-dismissing info notifications. No clipboard copy on success.
  /// If a run is already in progress, enqueues this job and notifies the user.
  func runImprovementFromVoice(transcribedInstruction: String, selectedText: String?, runInBackground: Bool = false) async {
    guard GeminiCredentialProvider.shared.hasCredential() else {
      await MainActor.run {
        PopupNotificationWindow.showError(
          "Add an API key in the General tab to use this feature.",
          title: "Smart Improvement"
        )
      }
      return
    }
    let instruction = transcribedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !instruction.isEmpty else {
      await MainActor.run {
        PopupNotificationWindow.showError(
          "No voice instruction received. Try again.",
          title: "Smart Improvement"
        )
      }
      return
    }
    if isImprovementRunning {
      improvementQueue.append(.fromVoice(instruction: instruction, selectedText: selectedText))
      showQueuedMessage()
      return
    }
    isImprovementRunning = true
    defer { isImprovementRunning = false }
    DebugLogger.log("AUTO-IMPROVEMENT: Voice-triggered run started (runInBackground: \(runInBackground))")
    await executeVoiceImprovement(instruction: instruction, selectedText: selectedText, runInBackground: runInBackground)
    DebugLogger.log("AUTO-IMPROVEMENT: Improve-from-voice run finished")
    await processNextInQueue()
  }

  /// True while an improvement run (manual or automatic) is in progress. Use to show "Running…" when the user returns to the Smart Improvement section.
  var isRunning: Bool { isImprovementRunning }

  /// Number of improvement jobs waiting in the queue (0 when none).
  var queuedJobCount: Int { improvementQueue.count }

  // MARK: - Private

  private enum ImprovementJob {
    case fromUsage
    case fromVoice(instruction: String, selectedText: String?)
  }

  private var isImprovementRunning = false
  private var improvementQueue: [ImprovementJob] = []

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
    case .fromVoice(let instruction, let selectedText):
      DebugLogger.log("AUTO-IMPROVEMENT: Processing queued from-voice job")
      await executeVoiceImprovement(instruction: instruction, selectedText: selectedText, runInBackground: true)
      DebugLogger.log("AUTO-IMPROVEMENT: Queued from-voice job finished")
    }
    await processNextInQueue()
  }

  /// Core voice-improvement logic. Does not manage isImprovementRunning or the queue.
  private func executeVoiceImprovement(instruction: String, selectedText: String?, runInBackground: Bool) async {
    if runInBackground {
      PopupNotificationWindow.showInfo(
        "Smart Improvement started. You'll be notified when done.",
        title: "Smart Improvement"
      )
    } else {
      PopupNotificationWindow.showProcessing(
        "Improving system prompts from your voice instruction...",
        title: "Smart Improvement"
      )
    }
    let derivation = ContextDerivation()
    let foci: [GenerationKind] = [.dictation, .promptMode, .promptAndRead]
    typealias FocusResult = (focus: GenerationKind, error: Error?)
    let results: [FocusResult] = await withTaskGroup(of: FocusResult.self) { group in
      for focus in foci {
        group.addTask {
          do {
            try await derivation.updateFromVoiceInstruction(
              voiceInstruction: instruction,
              selectedText: selectedText,
              focus: focus
            )
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
    var appliedKinds: [GenerationKind] = []
    for (focus, error) in results {
      if let error = error {
        DebugLogger.logError("AUTO-IMPROVEMENT: Voice derivation failed for \(focus): \(error.localizedDescription)")
        continue
      }
      if hasSuggestion(for: focus), let suggested = readSuggestion(for: focus), !suggested.isEmpty {
        applySuggestion(suggested, for: focus)
        appliedKinds.append(focus)
        DebugLogger.logSuccess("AUTO-IMPROVEMENT: Applied \(focus) from voice")
      } else {
        DebugLogger.log("AUTO-IMPROVEMENT: Skipped \(focus) — voice instruction not relevant to this mode")
      }
    }
    if !runInBackground {
      await MainActor.run {
        PopupNotificationWindow.dismissProcessing()
      }
    }
    if !appliedKinds.isEmpty {
      let kindNames = appliedKinds.map { kind -> String in
        switch kind {
        case .dictation: return "Dictation Prompt"
        case .promptMode: return "Dictate Prompt System Prompt"
        case .promptAndRead: return "Prompt & Read System Prompt"
        }
      }
      let message = "System prompts updated: \(kindNames.joined(separator: ", ")). Check Settings to review or revert."
      await MainActor.run {
        PopupNotificationWindow.showInfo(message, title: "Smart Improvement")
      }
    } else {
      await MainActor.run {
        PopupNotificationWindow.showInfo(
          "No suggestion could be generated from your instruction. Try rephrasing or check Settings.",
          title: "Smart Improvement"
        )
      }
    }
  }

  /// Current Smart Improvement model display name (e.g. "Gemini 3.1 Pro"). Same source as ContextDerivation.
  private func currentImprovementModelDisplayName() -> String? {
    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedImprovementModel)
      ?? SettingsDefaults.selectedImprovementModel.rawValue
    guard let model = PromptModel(rawValue: raw) else { return nil }
    return model.displayName
  }

  private func runImprovement() async {
    let derivation = ContextDerivation()
    var pendingKinds: [GenerationKind] = []

    // Run derivation for each focus
    let focuses: [GenerationKind] = [.dictation, .promptMode, .promptAndRead]

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
          "No suggestions could be generated (e.g. API busy). Try again later or check that you have interaction data.",
          title: "Smart Improvement"
        )
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

  /// Returns the current stored content for the given focus (after apply). Used to build clipboard output for improved sections only.
  private func currentContent(for kind: GenerationKind) -> String {
    let store = SystemPromptsStore.shared
    switch kind {
    case .dictation: return store.loadDictationPrompt()
    case .promptMode: return store.loadDictatePromptSystemPrompt()
    case .promptAndRead: return store.loadPromptAndReadSystemPrompt()
    }
  }

  private func readSuggestion(for kind: GenerationKind) -> String? {
    let contextDir = ContextLogger.shared.directoryURL
    let fileURL: URL

    switch kind {
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
    let section = kind.systemPromptSection
    let currentContent = SystemPromptsStore.shared.loadSection(section) ?? ""
    let previousLength = currentContent.count
    SystemPromptsStore.shared.updateSection(section, content: suggested)
    ContextLogger.shared.appendSystemPromptsHistory(section: section, previousLength: previousLength, newLength: suggested.count, content: suggested, model: improvementModel)
    switch kind {
    case .dictation: ContextLogger.shared.deleteSuggestedDictationPromptFile()
    case .promptMode: ContextLogger.shared.deleteSuggestedSystemPromptFile()
    case .promptAndRead: ContextLogger.shared.deleteSuggestedPromptAndReadSystemPromptFile()
    }
    let kindName: String = { switch kind { case .dictation: return "Dictation Prompt"; case .promptMode: return "Dictate Prompt"; case .promptAndRead: return "Prompt & Read" } }()
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
    case .promptMode: return .promptMode
    case .promptAndRead: return .promptAndRead
    }
  }
}

