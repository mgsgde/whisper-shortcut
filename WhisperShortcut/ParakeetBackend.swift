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
  // `@unchecked`: the only stored state is the `AsrManager` actor, set once in `load`.
  private let manager: AsrManager
  private static let version: AsrModelVersion = .ultra

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
  private static var ctcDirectory: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }

  /// Every file the transcriber and (from S2) the vocabulary booster load. Checked before any
  /// load, so a partial download surfaces as "not downloaded" rather than as a load attempt.
  static var isDownloaded: Bool {
    AsrModels.modelsExist(at: ultraDirectory, version: version)
      && CtcModels.modelsExist(at: ctcDirectory)
  }

  /// Downloads Ultra (~600 MB), then the CTC model (~100 MB) the Glossary needs. Progress is one
  /// 0…1 fraction across both, weighted by size, so Settings shows a single bar.
  static func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
    ModelHub.offlineMode = false
    defer { ModelHub.offlineMode = true }
    let ultraShare = 0.86
    try await AsrModels.download(version: version) { progress in
      onProgress(progress.fractionCompleted * ultraShare)
    }
    try Task.checkCancellation()
    try await CtcModels.download(variant: .ctc110m)
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
    ModelHub.offlineMode = true
    return try await AsrModels.load(from: directory, version: version)
  }

  func unload() async {
    await manager.cleanup()
  }

  // MARK: - Transcribe

  /// - Parameter language: ISO code from the Whisper language setting. Passed as FluidAudio's
  ///   script hint when it is one of the languages it knows; otherwise no hint (the model covers 25
  ///   European languages and picks among them itself).
  func transcribe(audioURL: URL, language: String?) async throws -> String {
    var state = TdtDecoderState.make(decoderLayers: Self.version.decoderLayers)
    let hint = language.flatMap(Language.init(rawValue:))
    let result = try await manager.transcribe(audioURL, decoderState: &state, language: hint)
    return result.text
  }
}

enum ParakeetBackendError: LocalizedError {
  case notDownloaded

  var errorDescription: String? {
    switch self {
    case .notDownloaded: return "Parakeet Ultra is not fully downloaded."
    }
  }
}
