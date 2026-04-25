import Foundation

enum ChatModelCommandOutcome: Equatable {
  case usage(current: PromptModel)
  case applied(model: PromptModel)
  case ambiguous(candidates: [PromptModel])
  case noMatch(query: String)
}

/// Pure resolver: maps a fuzzy `/model` argument to a `PromptModel` outcome.
/// Used by `ChatViewModel.handleModelCommand` so the matching logic can
/// be reasoned about without UI/state.
enum ChatModelCommandResolver {
  static func resolve(
    argument: String,
    currentSelection: PromptModel
  ) -> ChatModelCommandOutcome {
    let q = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty {
      return .usage(current: currentSelection)
    }

    // Exact rawValue match wins (after migrating removed 2.0 IDs).
    if let exact = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(q)) {
      return .applied(model: PromptModel.migrateIfDeprecated(exact))
    }

    // Normalize: lowercase, dashes → spaces, collapse whitespace.
    var normalized = q.lowercased().replacingOccurrences(of: "-", with: " ")
    while normalized.contains("  ") {
      normalized = normalized.replacingOccurrences(of: "  ", with: " ")
    }
    let padded = " \(normalized) "

    // Detect provider family first.
    let hasGrok = normalized.contains("grok")

    // Detect version family (order matters).
    var candidates: [PromptModel]
    if hasGrok {
      candidates = [.grok4, .grok4Reasoning, .grok4Fast]
    } else if normalized.contains("3.1") {
      candidates = [.gemini31Pro, .gemini31FlashLite]
    } else if normalized.contains("2.5") {
      candidates = [.gemini25Flash, .gemini25FlashLite, .gemini25Pro]
    } else if normalized.contains("2.0") || padded.contains(" 2 ") {
      candidates = [.gemini25Flash]
    } else if padded.contains(" 3 ") {
      candidates = [.gemini3Flash, .gemini3Pro]
    } else {
      candidates = PromptModel.allCases
    }

    // Keyword narrowing.
    let hasFlash = normalized.contains("flash")
    let hasLite = normalized.contains("lite")
    let hasFast = normalized.contains("fast")
    let hasReasoning = normalized.contains("reason")
    let hasPro = padded.contains(" pro") || normalized.hasPrefix("pro")

    if hasFast {
      let fasts = candidates.filter { isFast($0) }
      if !fasts.isEmpty { candidates = fasts }
    } else if hasReasoning {
      let reasonings = candidates.filter { isReasoning($0) }
      if !reasonings.isEmpty { candidates = reasonings }
    } else if hasFlash && hasLite {
      let lites = candidates.filter { isFlashLite($0) }
      if !lites.isEmpty { candidates = lites }
    } else if hasPro {
      let pros = candidates.filter { isPro($0) }
      if !pros.isEmpty { candidates = pros }
    } else if hasFlash {
      let flashesNoLite = candidates.filter { isFlash($0) && !isFlashLite($0) }
      if !flashesNoLite.isEmpty { candidates = flashesNoLite }
    }

    // When "grok 4" matches all Grok models but no narrowing keyword was given,
    // pick the base model (non-reasoning, non-fast) as the sensible default.
    if hasGrok && !hasFast && !hasReasoning && candidates.count > 1 {
      let base = candidates.filter { !isFast($0) && !isReasoning($0) }
      if base.count == 1 { candidates = base }
    }

    // Stable order based on PromptModel.allCases.
    let order = PromptModel.allCases
    candidates.sort { (a, b) in
      (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
    }

    if candidates.count == 1 {
      return .applied(model: PromptModel.migrateIfDeprecated(candidates[0]))
    }
    if candidates.isEmpty {
      return .noMatch(query: argument)
    }
    return .ambiguous(candidates: candidates)
  }

  private static func isFlashLite(_ m: PromptModel) -> Bool {
    switch m {
    case .gemini25FlashLite, .gemini31FlashLite: return true
    default: return false
    }
  }

  private static func isFlash(_ m: PromptModel) -> Bool {
    switch m {
    case .gemini25Flash, .gemini25FlashLite, .gemini3Flash, .gemini31FlashLite: return true
    default: return false
    }
  }

  private static func isPro(_ m: PromptModel) -> Bool {
    switch m {
    case .gemini25Pro, .gemini3Pro, .gemini31Pro: return true
    default: return false
    }
  }

  private static func isFast(_ m: PromptModel) -> Bool {
    switch m {
    case .grok4Fast: return true
    default: return false
    }
  }

  private static func isReasoning(_ m: PromptModel) -> Bool {
    switch m {
    case .grok4Reasoning: return true
    default: return false
    }
  }
}
