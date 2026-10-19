import Foundation

// MARK: - Curated model pickers
//
// Every model picker (Dictate, Dictate Prompt, Read Aloud, Chat, Meeting Transcription / Summary,
// Smart Improvement) opens with at most three tiles — Recommended · Fastest · Offline — and keeps
// the rest behind "More models". The 2026-10-19 UX review found 16–18 near-identical tiles per
// picker (five Gemini Flash variants nobody could tell apart); the curation is the fix.
//
// What is featured is decided here, from data on the model enums, never from string lists in the
// views: `pickerSpeedRank` names the fastest, `pickerOfflineRank` the on-device pick,
// `pickerSupersededBy` hides a dominated sibling, and the recommendation stays where it always was
// (`SettingsDefaults`, passed in by each picker because Chat and Meeting Summary recommend
// different models from the same enum).
//
// Recommended and Fastest only go to models that can run with the credentials the user has
// (`pickerSetupBadge == nil`). Before, a Gemini-only user opened Dictate to "Recommended: GPT
// Transcribe — Needs key" and "Fastest: Grok STT — Needs key", with their own model fourth, while
// onboarding had told them one account is enough.

/// Why a model sits in a picker's top row. A model can carry several (Read Aloud's default is
/// also its fastest).
enum ModelPickerBadge: Hashable, CaseIterable {
  case recommended
  case fastest
  case offline

  var title: String {
    switch self {
    case .recommended: return "Recommended"
    case .fastest: return "Fastest"
    case .offline: return "Offline"
    }
  }

  var symbol: String {
    switch self {
    case .recommended: return "star.fill"
    case .fastest: return "bolt.fill"
    case .offline: return "desktopcomputer"
    }
  }
}

/// The per-model facts a curated picker needs. Implemented by `TranscriptionModel`, `PromptModel`
/// and `TTSModel` below.
protocol PickerCuratedModel: Hashable {
  /// Lower is faster at this model's job. `nil` = never featured as Fastest: no measurement, or a
  /// routed / self-configured entry whose speed is whatever the user pointed it at. On-device
  /// models carry `nil` — they compete for the Offline slot instead.
  var pickerSpeedRank: Int? { get }
  /// Lower is the better on-device pick. `nil` for anything that leaves the Mac.
  var pickerOfflineRank: Int? { get }
  /// A newer sibling that beats this model on every axis that matters for the picker. Superseded
  /// models disappear from every picker unless they are the current selection — and only while
  /// the replacement is actually offered there, so nothing is hidden in favour of a model the
  /// user cannot pick.
  var pickerSupersededBy: Self? { get }
  /// Short tile badge when the model cannot run yet for lack of a key or setup ("Needs key",
  /// "Needs setup"); `nil` when it is ready. Tiles stay selectable either way — one rule for
  /// every picker (UX review #14) instead of some dimming and some failing later.
  var pickerSetupBadge: String? { get }
  /// Lower is the better replacement for the picker's recommendation when that one cannot run.
  /// Mirrors `ModelSelectionReconciler`, so the Recommended tile names the model the reconciler
  /// would select for this user. `nil` = not a stand-in: on-device models, which have their own
  /// step in the fallback order, and models the reconciler never substitutes.
  var pickerStandInRank: Int? { get }
}

/// The curated split of one picker's models: the top row and the "More models" remainder.
struct ModelPickerCuration<Model: PickerCuratedModel> {
  struct Featured: Hashable {
    let model: Model
    /// Empty only for the current selection when it is none of Recommended / Fastest / Offline.
    let badges: [ModelPickerBadge]
  }

  /// Recommended, Fastest, Offline (each at most once, merged when one model wins two), then the
  /// current selection if it was none of those.
  let featured: [Featured]
  /// Everything else that is visible, in the order the picker passed it.
  let more: [Model]

  /// Below this many visible models the disclosure is not worth a click: everything is featured.
  static var disclosureThreshold: Int { 5 }

  /// `isUsable` says whether a model can run with the credentials the user has now. The default
  /// reads the keychain through `pickerSetupBadge`; tests pass a closure so they stay pure.
  init(
    models: [Model], recommended: Model?, selected: Model,
    isUsable: (Model) -> Bool = { $0.pickerSetupBadge == nil }
  ) {
    let visible = Self.visibleModels(models, selected: selected)
    let usable = visible.filter(isUsable)
    // With nothing usable (no key at all and no on-device model in this picker) the slots keep the
    // global choice: an honest "Needs key" tile beats an empty top row.
    let candidates = usable.isEmpty ? visible : usable

    var featured: [Featured] = []
    func feature(_ model: Model?, as badge: ModelPickerBadge) {
      guard let model, visible.contains(model) else { return }
      if let index = featured.firstIndex(where: { $0.model == model }) {
        featured[index] = Featured(model: model, badges: featured[index].badges + [badge])
      } else {
        featured.append(Featured(model: model, badges: [badge]))
      }
    }

    feature(Self.recommendation(recommended, among: candidates), as: .recommended)
    feature(Self.best(candidates, by: \.pickerSpeedRank), as: .fastest)
    // On-device models never need a key, so the Offline slot does not depend on credentials.
    feature(Self.best(visible, by: \.pickerOfflineRank), as: .offline)

    if visible.count < Self.disclosureThreshold {
      // Short lists (Read Aloud in Offline Mode, a Mac with one provider) stay fully visible.
      let rest = visible.filter { model in !featured.contains { $0.model == model } }
      featured += rest.map { Featured(model: $0, badges: []) }
    } else if visible.contains(selected), !featured.contains(where: { $0.model == selected }) {
      featured.append(Featured(model: selected, badges: []))
    }

    self.featured = featured
    self.more = visible.filter { model in !featured.contains { $0.model == model } }
  }

  /// `models` without superseded entries — except the current selection, and except where the
  /// replacement is not offered in this picker.
  static func visibleModels(_ models: [Model], selected: Model) -> [Model] {
    models.filter { model in
      guard model != selected, let replacement = model.pickerSupersededBy else { return true }
      return !models.contains(replacement)
    }
  }

  /// The picker's default if it is among `candidates`, else the best candidate in this order:
  /// 1. the lowest `pickerStandInRank` — each provider's own pick, providers in the reconciler's
  ///    order (Gemini, OpenAI, xAI, OpenRouter), so the tile matches what the user is moved to;
  /// 2. the lowest `pickerOfflineRank` — with no cloud key, the on-device model is the one that
  ///    works (the reconciler makes the same move for Dictate Prompt and Chat);
  /// 3. the first candidate in list order.
  /// `nil` only when the picker offers nothing at all.
  static func recommendation(_ recommended: Model?, among candidates: [Model]) -> Model? {
    if let recommended, candidates.contains(recommended) { return recommended }
    return best(candidates, by: \.pickerStandInRank)
      ?? best(candidates, by: \.pickerOfflineRank)
      ?? candidates.first
  }

  /// The model with the lowest rank; ties go to the earlier entry so list order breaks them.
  private static func best(_ models: [Model], by rank: KeyPath<Model, Int?>) -> Model? {
    models
      .compactMap { model in model[keyPath: rank].map { (model, $0) } }
      .min { $0.1 < $1.1 }?
      .0
  }
}

// MARK: - Transcription (Dictate, Meeting Transcription)

extension TranscriptionModel: PickerCuratedModel {
  /// Median latency order on a 1.3 s clip, `plans/model-audits/2026-10-03-audit.md`
  /// (Transcription benchmark): grok-stt 424 ms · gpt-4o-transcribe 645 · gpt-4o-mini 654 ·
  /// gpt-transcribe 673 · 3.1 Flash-Lite 968 · 3.5 Flash-Lite 973 · 3.8 Flash 1286 · 3.7 Flash 1822.
  /// Re-rank when the monthly audit's table moves.
  var pickerSpeedRank: Int? {
    switch self {
    case .xaiTranscribe: return 1
    case .openAIGPT4oTranscribe: return 2
    case .openAIGPT4oMiniTranscribe: return 3
    case .openAIGPTTranscribe: return 4
    case .gemini31FlashLite: return 5
    case .gemini35FlashLite: return 6
    case .gemini38Flash: return 7
    case .gemini37Flash: return 8
    case .gemini31Pro, .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge,
         .whisperLargeTurbo, .parakeetUltra, .selfHostedTranscription, .openRouterTranscription:
      return nil
    }
  }

  /// The language-aware offline recommendation first (Parakeet Ultra, or Large v3 Turbo for
  /// languages Parakeet does not cover — see `isRecommended`), then by accuracy.
  var pickerOfflineRank: Int? {
    guard isOffline else { return nil }
    if isRecommended { return 0 }
    switch self {
    case .parakeetUltra: return 1
    case .whisperLargeTurbo: return 2
    case .whisperSmall: return 3
    case .whisperBase: return 4
    case .whisperTiny: return 5
    default: return nil
    }
  }

  /// Gemini 3.7 Flash is strictly dominated by 3.8 Flash *for transcription* — same price and
  /// context, same 76% glossary, fewer silence leaks (7/9 vs 9/9), faster at every clip length
  /// (`plans/model-audits/2026-10-03-audit.md`, Pareto check). It stays in the enum and in the
  /// Dictate Prompt / Chat lists, where the two measured as a tie.
  ///
  /// Whisper Medium / Large are superseded by Large v3 Turbo too, but that is already handled by
  /// `isSelectableForDictation`, which deliberately keeps a downloaded copy offered.
  var pickerSupersededBy: TranscriptionModel? {
    switch self {
    case .gemini37Flash: return .gemini38Flash
    default: return nil
    }
  }

  var pickerSetupBadge: String? {
    switch provider {
    // A missing offline file is a download, not a key — the offline section handles it.
    case .offline: return nil
    case .selfHosted: return hasRequiredCredential ? nil : "Needs setup"
    case .google, .openAI, .xai, .openRouter: return hasRequiredCredential ? nil : "Needs key"
    }
  }

  /// `ModelSelectionReconciler.transcriptionReplacement` in `providerPreference` order, plus
  /// OpenRouter last: the reconciler has no transcription stand-in for it, but a user who
  /// connected only OpenRouter can dictate through it, and that tile is the one to recommend.
  var pickerStandInRank: Int? {
    switch self {
    case .gemini31FlashLite: return 0
    case .openAIGPTTranscribe: return 1
    case .xaiTranscribe: return 2
    case .openRouterTranscription: return 3
    default: return nil
    }
  }
}

// MARK: - Prompt models (Dictate Prompt, Chat, Meeting Summary, Smart Improvement)

extension PromptModel: PickerCuratedModel {
  /// Only the Gemini tiers are ranked: they are the ones measured against each other in the app's
  /// own request shape (Flash-Lite runs `thinkingLevel: minimal`, Flash cannot go below `low`;
  /// audio latency 968 / 973 / 1286 / 1822 ms in `plans/model-audits/2026-10-03-audit.md`).
  /// Other providers have no comparable measurement, so none is called fastest on a guess.
  var pickerSpeedRank: Int? {
    switch self {
    case .gemini31FlashLite: return 1
    case .gemini35FlashLite: return 2
    case .gemini38Flash: return 3
    case .gemini37Flash: return 4
    default: return nil
    }
  }

  /// In-process MLX first — nothing to install — with the catalogue's recommendation ahead; an
  /// Ollama / LM Studio server last because it only works once the user runs one.
  var pickerOfflineRank: Int? {
    if let type = localMLXModelType { return type.isRecommended ? 0 : 1 }
    return provider == .local ? 2 : nil
  }

  /// The same supersession Chat has always applied (`chatReplacement`), now for every picker.
  var pickerSupersededBy: PromptModel? { chatReplacement }

  var pickerSetupBadge: String? {
    guard !hasRequiredCredential else { return nil }
    if case .endpoint = provider.credentialRequirement { return "Needs setup" }
    return "Needs key"
  }

  /// `ModelSelectionReconciler.preferredPromptModel`: providers in `providerPreference` order,
  /// each provider's `defaultChatModel` ahead of its other models (list order breaks the rest).
  /// Anthropic comes last: the reconciler never substitutes it, but a Claude key is still a
  /// better recommendation than an on-device model.
  var pickerStandInRank: Int? {
    let order = ModelSelectionReconciler.providerPreference + [.anthropic]
    guard let index = order.firstIndex(of: provider) else { return nil }
    return index * 2 + (self == provider.defaultChatModel ? 0 : 1)
  }
}

// MARK: - Read Aloud

extension TTSModel: PickerCuratedModel {
  /// Measured 2026-09-29 (see the `TTSModel` note): Gemini 3.8 Flash-Lite TTS first audio
  /// 0.6–0.75 s, Flash TTS 1.1–1.5 s. OpenAI / xAI were not timed side by side.
  var pickerSpeedRank: Int? {
    switch self {
    case .gemini38FlashLiteTTS: return 1
    case .gemini38FlashTTS: return 2
    case .openAIGpt4oMiniTTS, .grokVoiceTTS, .systemMacOS: return nil
    }
  }

  var pickerOfflineRank: Int? { provider == .system ? 0 : nil }

  var pickerSupersededBy: TTSModel? { nil }

  var pickerSetupBadge: String? { hasRequiredCredential ? nil : "Needs key" }

  /// The reconciler takes the first keyed entry of `readAloudModels`, which is the macOS voice;
  /// leaving every rank `nil` lets the curation reach the same model through its Offline step.
  var pickerStandInRank: Int? { nil }
}
