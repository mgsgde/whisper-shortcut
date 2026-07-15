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

    // OpenInference / custom endpoint aliases before provider-family detection.
    var normalizedEarly = q.lowercased().replacingOccurrences(of: "-", with: " ")
    while normalizedEarly.contains("  ") {
      normalizedEarly = normalizedEarly.replacingOccurrences(of: "  ", with: " ")
    }
    if normalizedEarly == "custom"
      || normalizedEarly.contains("openinference")
      || normalizedEarly.contains("open inference")
      || normalizedEarly.contains("glm")
    {
      return .applied(model: .customOpenAIEndpoint)
    }

    // Exact rawValue match wins (after migrating removed 2.0 IDs), but only
    // for models eligible for chat — audio-only models live in Dictate Prompt.
    if let exact = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue(q)) {
      let migrated = PromptModel.migrateIfDeprecated(exact)
      if PromptModel.chatModels.contains(migrated) {
        return .applied(model: migrated)
      }
    }

    // Normalize: lowercase, dashes → spaces, collapse whitespace.
    var normalized = q.lowercased().replacingOccurrences(of: "-", with: " ")
    while normalized.contains("  ") {
      normalized = normalized.replacingOccurrences(of: "  ", with: " ")
    }
    let padded = " \(normalized) "

    // Detect provider family first.
    let hasGrok = normalized.contains("grok")
    let hasClaude = !hasGrok && (
      normalized.contains("claude") ||
      normalized.contains("anthropic") ||
      normalized.contains("sonnet") ||
      normalized.contains("opus") ||
      normalized.contains("haiku")
    )
    // "gpt"/"openai"/"4o" pull the user toward OpenAI before the generic " 3 "
    // branch can mis-route "gpt 3" to Gemini 3.
    let hasOpenAI = !hasGrok && !hasClaude && (
      normalized.contains("openai") ||
      normalized.contains("gpt") ||
      normalized.contains("4o")
    )

    // Native image generation (Nano Banana) — match before the version branches so "image"
    // or "nano banana" routes to the image model regardless of any "3.1"/"flash" it contains.
    // Guarded by !grok/!openai/!claude so a hypothetical "gpt image" wouldn't get hijacked.
    let wantsImage = !hasGrok && !hasOpenAI && !hasClaude
      && (padded.contains(" image ") || normalized.contains("nano banana"))

    // Detect version family (order matters).
    var candidates: [PromptModel]
    if wantsImage {
      // Both image tiers; the "pro" keyword narrowing below picks Nano Banana Pro,
      // and a bare "image"/"nano banana" defaults to the free Flash tier further down.
      candidates = [.geminiImage, .geminiImagePro]
    } else if hasGrok {
      if normalized.contains("4.3") {
        candidates = [.grok43]
      } else {
        candidates = [.grok4, .grok4Reasoning, .grok43]
      }
    } else if hasClaude {
      if normalized.contains("opus") {
        candidates = [.claudeOpus48]
      } else if normalized.contains("haiku") {
        candidates = [.claudeHaiku45]
      } else if normalized.contains("sonnet") {
        candidates = [.claudeSonnet5]
      } else {
        candidates = [.claudeSonnet5, .claudeOpus48, .claudeHaiku45]
      }
    } else if hasOpenAI {
      // openaiGPT4oAudio is Dictate-Prompt only (supportsTextChat=false), so
      // the chat resolver returns only the text-capable OpenAI models.
      if normalized.contains("5.5") {
        candidates = [.openaiGPT55]
      } else {
        candidates = [.openaiGPT5, .openaiGPT5Mini, .openaiGPT55]
      }
    } else if normalized.contains("3.5") {
      candidates = [.gemini35Flash]
    } else if normalized.contains("3.1") {
      candidates = [.gemini31Pro, .gemini31FlashLite]
    } else if padded.contains(" 3 ") {
      // Bare "Gemini 3" → the current 3-series flagship Flash.
      candidates = [.gemini35Flash]
    } else {
      candidates = PromptModel.chatModels
    }

    // Keyword narrowing.
    let hasFlash = normalized.contains("flash")
    let hasLite = normalized.contains("lite")
    let hasFast = normalized.contains("fast")
    let hasReasoning = normalized.contains("reason")
    let hasPro = padded.contains(" pro") || normalized.hasPrefix("pro")
    let hasMini = normalized.contains("mini")

    if hasFast {
      let fasts = candidates.filter { isFast($0) }
      if !fasts.isEmpty { candidates = fasts }
    } else if hasReasoning {
      let reasonings = candidates.filter { isReasoning($0) }
      if !reasonings.isEmpty { candidates = reasonings }
    } else if hasLite {
      // "lite" (with or without "flash") narrows to the FlashLite variant; must precede the
      // plain `hasFlash` branch so "flash lite" doesn't get coerced to non-lite Flash.
      let lites = candidates.filter { isFlashLite($0) }
      if !lites.isEmpty { candidates = lites }
    } else if hasPro {
      let pros = candidates.filter { isPro($0) }
      if !pros.isEmpty { candidates = pros }
    } else if hasFlash {
      let flashesNoLite = candidates.filter { isFlash($0) && !isFlashLite($0) }
      if !flashesNoLite.isEmpty { candidates = flashesNoLite }
    } else if hasMini {
      let minis = candidates.filter { isMini($0) }
      if !minis.isEmpty { candidates = minis }
    }

    // When the user typed ONLY the provider name (e.g. `/model grok`, `/model openai`)
    // with no version or variant, pick that provider's canonical default. Source of
    // truth lives on `ChatModelProvider.defaultChatModel` so this branch, the bare
    // `/gemini` / `/grok` / `/gpt` dispatch in ChatView, and the autocomplete hint
    // never disagree. If the user typed any qualifier (e.g. `/model grok 4.20`,
    // `/model openai gpt-5`) we leave the candidate list alone so an explicit
    // version doesn't get silently coerced to the family default.
    let lowered = q.lowercased()
    if lowered == "grok" && candidates.count > 1 {
      let preferred = ChatModelProvider.grok.defaultChatModel
      if candidates.contains(preferred) { candidates = [preferred] }
    }
    if lowered == "openai" && candidates.count > 1 {
      let preferred = ChatModelProvider.openai.defaultChatModel
      if candidates.contains(preferred) { candidates = [preferred] }
    }
    if (lowered == "claude" || lowered == "anthropic") && candidates.count > 1 {
      let preferred = ChatModelProvider.anthropic.defaultChatModel
      if candidates.contains(preferred) { candidates = [preferred] }
    }
    // Same idea for the image family: an image request without a "pro" qualifier
    // ("image", "nano banana", "gemini image", …) picks the free Flash tier;
    // "image pro" / "nano banana pro" were already narrowed to Pro above.
    if wantsImage && candidates.count > 1, candidates.contains(.geminiImage) {
      candidates = [.geminiImage]
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
    case .gemini31FlashLite: return true
    default: return false
    }
  }

  private static func isFlash(_ m: PromptModel) -> Bool {
    switch m {
    case .gemini31FlashLite, .gemini35Flash,
         .geminiImage: return true  // "flash image" → the Flash-tier image model
    default: return false
    }
  }

  private static func isPro(_ m: PromptModel) -> Bool {
    switch m {
    case .gemini31Pro, .geminiImagePro: return true
    default: return false
    }
  }

  private static func isFast(_ m: PromptModel) -> Bool {
    switch m {
    case .grok43: return true  // grok-4.3 is xAI's "fastest, most intelligent" since 2026-05-06.
    case .claudeHaiku45: return true
    default: return false
    }
  }

  private static func isReasoning(_ m: PromptModel) -> Bool {
    switch m {
    case .grok4Reasoning: return true
    default: return false
    }
  }

  private static func isMini(_ m: PromptModel) -> Bool {
    switch m {
    case .openaiGPT5Mini: return true
    default: return false
    }
  }
}
