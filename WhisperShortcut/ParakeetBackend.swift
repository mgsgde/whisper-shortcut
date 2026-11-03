//
//  ParakeetBackend.swift
//  WhisperShortcut
//
//  Parakeet Ultra (NVIDIA Parakeet TDT 0.6B v3, retrained by Moondream) through FluidAudio.
//  The only file that imports FluidAudio — its `Language`, `AudioConverter` and friends stay out
//  of the rest of the app's namespace.
//

import Foundation
import FluidAudio

/// Offline dictation on a FastConformer/TDT model instead of Whisper.
///
/// Why this exists is in `LocalSpeechService`'s doc comment and in
/// `benchmarks/local-asr/README.md` → Results: on the user's own German recordings Parakeet Ultra
/// matched Whisper large-v3 turbo's accuracy (8.1 % vs 8.4 % WER against the cloud transcript) at
/// about 1/20 of the wait — 0.1 s instead of 1.9 s for a sentence, 0.5 s instead of 10 s for a
/// minute — because its encoder does not pad every call to a 30 s window.
///
/// Files live where FluidAudio puts them by default, `Application Support/FluidAudio/Models/`.
/// Both app targets are sandboxed, so that is inside the app container, next to
/// `WhisperShortcut/`. Keeping FluidAudio's default matters: its vocabulary boosting
/// (`VocabularyBoostingSession`) looks the CTC tokenizer up in the default directory, whatever
/// directory the models were loaded from.
final class ParakeetBackend: @unchecked Sendable {
  // `@unchecked`: every stored property is an actor or `Sendable`, and none is reassigned.
  fileprivate let manager: AsrManager
  private let vocabulary = VocabularyBooster()
  fileprivate static let version: AsrModelVersion = .ultra
  private let converter = AudioConverter()

  private init(manager: AsrManager) {
    self.manager = manager
  }

  // MARK: - Files

  /// FluidAudio's model root. Holds exactly the Parakeet download (Ultra + the CTC model), so it
  /// is also what Settings deletes and sizes.
  static var modelsRoot: URL {
    AsrModels.defaultCacheDirectory(for: version).deletingLastPathComponent()
  }

  private static var ultraDirectory: URL { AsrModels.defaultCacheDirectory(for: version) }
  /// Internal (not private) so the live test can remove just this part and watch it re-download.
  static var ctcDirectory: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }

  /// Every file the transcriber and (from S2) the vocabulary booster load. Checked before any
  /// load, so a partial download surfaces as "not downloaded" rather than as a load attempt.
  static var isDownloaded: Bool {
    AsrModels.modelsExist(at: ultraDirectory, version: version)
      && CtcModels.modelsExist(at: ctcDirectory)
  }

  /// Downloads Ultra (~600 MB), then the CTC model (~100 MB) the Glossary needs. Progress is one
  /// 0…1 fraction across both, weighted by size, so Settings shows a single bar.
  static func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
    _ = networkShutByDefault
    ModelHub.offlineMode = false
    defer { ModelHub.offlineMode = true }
    let ultraShare = 0.86
    try await AsrModels.download(version: version) { progress in
      onProgress(progress.fractionCompleted * ultraShare)
    }
    try Task.checkCancellation()
    // `CtcModels.download` reports no progress, which left the bar sitting at 86 % for the whole
    // ~100 MB. The ModelHub call underneath it does report, so the files come from there…
    if !CtcModels.modelsExist(at: ctcDirectory) {
      try await ModelHub.download(
        CtcModelVariant.ctc110m.repo, to: ctcDirectory.deletingLastPathComponent()
      ) { progress in
        onProgress(ultraShare + progress.fractionCompleted * (1 - ultraShare))
      }
    }
    try Task.checkCancellation()
    // …and one load compiles the model now, as `CtcModels.download` did, so the first dictation
    // with a Glossary does not pay for it.
    _ = try await CtcModels.load(from: ctcDirectory)
    onProgress(1)
  }

  // MARK: - Load

  /// Weights into memory. The first load after a download compiles the models for the Neural
  /// Engine; later loads come from the system's compile cache (0.4 s measured on an M1 Pro).
  ///
  /// FluidAudio's network switch is forced shut first. Left open, its loader contacts
  /// HuggingFace on its own: it re-downloads when a file is missing or the cached revision marker
  /// does not match, and on a load failure it *deletes the whole model folder* and fetches it again.
  /// None of that may happen at dictation time — not in Offline Mode, not in a practice without
  /// internet, and not as a silent 600 MB download. A load failure is surfaced instead, and
  /// Settings' Delete + Download is the repair. The switch opens only inside `download`.
  static func load() async throws -> ParakeetBackend {
    guard isDownloaded else {
      throw ParakeetBackendError.notDownloaded
    }
    let models = try await loadModelsOffline(from: ultraDirectory)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    return ParakeetBackend(manager: manager)
  }

  /// The FluidAudio load call with the network switch shut. Separate so a test can point it at
  /// an empty folder and see it fail as "missing" instead of reaching for HuggingFace.
  static func loadModelsOffline(from directory: URL) async throws -> AsrModels {
    _ = networkShutByDefault
    return try await AsrModels.load(from: directory, version: version)
  }

  /// FluidAudio's network switch, shut once per process before its first use. Loads only read
  /// it — writing it from every load could flip it back on under a running Settings download,
  /// which FluidAudio checks per request and would abort. Only `download` opens it, and puts it
  /// back when done.
  fileprivate static let networkShutByDefault: Void = { ModelHub.offlineMode = true }()

  // No `unload()`: `AsrManager.cleanup()` nils the models a decode in flight is still reading
  // across its suspension points, which failed dictations as "not initialized" when memory
  // pressure or a model switch unloaded mid-decode. Dropping the last reference to this object
  // frees everything once any running decode has let go of it.

  // MARK: - Transcribe

  /// - Parameters:
  ///   - language: ISO code from the Whisper language setting. Passed as FluidAudio's script hint
  ///     when it is one of the languages it knows; otherwise no hint (the model covers 25 European
  ///     languages and picks among them itself).
  ///   - vocabulary: the Glossary as terms (`SpeechService.glossaryKeywords`). Parakeet takes no
  ///     conditioning text; instead FluidAudio's CTC keyword spotter listens for these terms in the
  ///     audio and rescores the transcript where it hears one. Benchmarked on German practice
  ///     terms: 18/24 → 23/24, for ~0.2 s on a short clip. Empty → the plain, faster path.
  ///   - spokenMarksOnly: "Only when spoken" punctuation. Parakeet's own commas and periods are
  ///     kept only where the token timings show speech time behind them
  ///     (`ParakeetPunctuationTiming`); the rest are removed. When the marks in the text cannot be
  ///     matched to the tokens, the old rule applies (commas out, periods stay).
  func transcribe(
    audioURL: URL, language: String?, vocabulary terms: [String], spokenMarksOnly: Bool = false
  ) async throws -> String {
    var state = TdtDecoderState.make(decoderLayers: Self.version.decoderLayers)
    let hint = language.flatMap(Language.init(rawValue:))
    if let language, hint == nil {
      DebugLogger.logWarning(
        "LOCAL-SPEECH: Parakeet does not cover language '\(language)'; transcribing without a hint")
    }
    do {
      guard !terms.isEmpty else {
        let result = try await manager.transcribe(audioURL, decoderState: &state, language: hint)
        return spokenMarksOnly
          ? Self.keepingSpokenMarks(result, audioURL: audioURL)
          : ParakeetPunctuationTiming.spacingGluedCommas(result.text)
      }
      // The spotter needs the samples too, so decode from them rather than reading the file twice.
      let samples = try converter.resampleAudioFile(audioURL)
      let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
      let rescored = await vocabulary.rescore(result, samples: samples, terms: terms)
      // After the rescore, which reads `result.text` with its token timings and needs them to
      // agree. It only rewrites word spans; the filter maps marks to tokens by order and falls
      // back when a span swallowed one (count mismatch).
      return spokenMarksOnly
        ? Self.keepingSpokenMarks(result, text: rescored, audioURL: audioURL)
        : ParakeetPunctuationTiming.spacingGluedCommas(rescored)
    } catch let error as ASRError {
      switch error {
      case .invalidAudioData: throw ParakeetBackendError.audioTooShort
      case .notInitialized: throw ParakeetBackendError.notLoaded
      default: throw error
      }
    }
  }
}

extension ParakeetBackend {
  /// `text` (default: the decode's own) with the marks Parakeet guessed removed. Counts only, never
  /// the dictated text, go to the log.
  fileprivate static func keepingSpokenMarks(
    _ result: ASRResult, text: String? = nil, audioURL: URL
  ) -> String {
    let text = text ?? result.text
    let tokens = (result.tokenTimings ?? []).map {
      ParakeetPunctuationTiming.Token(text: $0.token, start: $0.startTime, end: $0.endTime)
    }
    if let duration = try? AudioDuration.avAudioFileSeconds(audioURL),
      let filtered = ParakeetPunctuationTiming.filter(
        text: text, tokens: tokens, audioDuration: duration)
    {
      DebugLogger.log(
        "LOCAL-SPEECH: punctuation timing kept=\(filtered.kept) dropped=\(filtered.dropped)")
      return filtered.text
    }
    DebugLogger.log("LOCAL-SPEECH: punctuation timing skipped (count mismatch)")
    return SpokenPunctuation.stripModelPunctuation(
      from: ParakeetPunctuationTiming.spacingGluedCommas(text))
  }

  /// The raw decode with its token timings, for the opt-in live tests only (no app code calls
  /// it). Plain value types so the test target does not need to import FluidAudio.
  func rawTokenTimings(audioURL: URL, language: String?) async throws
    -> (text: String, tokens: [(token: String, start: Double, end: Double)])
  {
    var state = TdtDecoderState.make(decoderLayers: Self.version.decoderLayers)
    let hint = language.flatMap(Language.init(rawValue:))
    let result = try await manager.transcribe(audioURL, decoderState: &state, language: hint)
    let tokens = (result.tokenTimings ?? []).map {
      (token: $0.token, start: $0.startTime, end: $0.endTime)
    }
    return (result.text, tokens)
  }
}

/// CTC vocabulary boosting for one glossary at a time.
///
/// Building a session tokenises every term and loads the CTC model (~100 MB), so it is built on
/// the first dictation that has a glossary and reused until the glossary text changes. An actor
/// because a meeting's live chunks and a dictation can decode side by side.
private actor VocabularyBooster {
  /// A task, not a value: two cold-cache rescores (a meeting chunk and a dictation) would
  /// otherwise both pass a nil check across the `await` and load the ~100 MB model twice.
  private var ctcLoad: Task<CtcModels, Error>?
  private var session: (terms: [String], session: VocabularyBoostingSession)?

  /// The rescored transcript, or the plain one when boosting cannot run — a missing CTC model or
  /// a glossary with no usable term must cost the Glossary, never the dictation.
  func rescore(_ result: ASRResult, samples: [Float], terms: [String]) async -> String {
    do {
      let session = try await session(for: terms)
      let rescored = await session.rescore(
        text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
      guard let rescored, rescored.wasModified else {
        return ParakeetVocabularyGuard.restoreGlossaryCasing(
          in: result.text, glossaryTerms: terms)
      }
      let candidates = rescored.replacements.filter(\.shouldReplace).compactMap {
        replacement -> ParakeetVocabularyGuard.Replacement? in
        guard let term = replacement.replacementWord else { return nil }
        return ParakeetVocabularyGuard.Replacement(
          originalSpan: replacement.originalWord, term: term)
      }
      let applied = ParakeetVocabularyGuard.apply(
        to: result.text, replacements: candidates, glossaryTerms: terms)
      if applied.rejected > 0 {
        DebugLogger.log(
          "LOCAL-SPEECH: Parakeet vocabulary rejected \(applied.rejected) replacement(s)")
      }
      if applied.accepted > 0 {
        DebugLogger.log(
          "LOCAL-SPEECH: Parakeet vocabulary applied \(applied.accepted) replacement(s)")
      }
      return ParakeetVocabularyGuard.restoreGlossaryCasing(
        in: applied.text, glossaryTerms: terms)
    } catch {
      DebugLogger.logWarning(
        "LOCAL-SPEECH: Parakeet vocabulary boosting skipped (\(error.localizedDescription))")
      return result.text
    }
  }

  private func session(for terms: [String]) async throws -> VocabularyBoostingSession {
    if let cached = session, cached.terms == terms { return cached.session }
    let load = ctcLoad ?? Task {
      // Same network rule as the transcriber: the CTC model goes through FluidAudio's ModelHub.
      _ = ParakeetBackend.networkShutByDefault
      return try await CtcModels.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
    }
    ctcLoad = load
    let ctcModels: CtcModels
    do {
      ctcModels = try await load.value
    } catch {
      ctcLoad = nil  // retry on the next dictation rather than caching the failure
      throw error
    }
    let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
    // FluidAudio's default similarity floor is 0, so its spotter rescue can swap up to four
    // unrelated words for a term ("weitere Einschränkungen liegen nicht vor" became "Diarrhöe nicht
    // vor" with only "Diarrhoe" in the glossary). `itnDefaultConfig` carries the floors FluidAudio
    // sets for ITN engines; they are used here to stop that, at the cost of some recall on heavily
    // mangled terms.
    let built = try await VocabularyBoostingSession(
      vocabulary: context, ctcModels: ctcModels, config: VocabularyBoostingSession.itnDefaultConfig)
    session = (terms, built)
    DebugLogger.log("LOCAL-SPEECH: Parakeet vocabulary built from \(terms.count) glossary term(s)")
    return built
  }
}

enum ParakeetBackendError: LocalizedError {
  case notDownloaded
  /// FluidAudio refuses audio under 0.3 s — a tap, not a dictation.
  case audioTooShort
  /// The models went away under a decode; the caller reloads once and retries.
  case notLoaded

  var errorDescription: String? {
    switch self {
    case .notDownloaded: return String(localized: "Parakeet Ultra is not fully downloaded.")
    case .audioTooShort: return String(localized: "The recording is too short to transcribe.")
    case .notLoaded: return String(localized: "Parakeet Ultra was not loaded.")
    }
  }
}
