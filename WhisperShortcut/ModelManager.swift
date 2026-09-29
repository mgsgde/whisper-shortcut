//
//  ModelManager.swift
//  WhisperShortcut
//
//  Catalogue and download/load path for offline dictation models — WhisperKit and Parakeet
//  (FluidAudio, see `ParakeetBackend`). The shared download bookkeeping is `ModelStore`.
//

import Foundation
import Combine
import WhisperKit

// MARK: - Model Type Enum

/// Which on-device speech engine runs a model. `LocalSpeechService` and `ModelManager` branch on
/// this; everything above them treats every offline model alike.
enum OfflineEngine {
  case whisperKit
  case parakeet
}

enum OfflineModelType: String, CaseIterable, DownloadableModel {
  // Whisper models for transcription (WhisperKit CoreML models)
  case whisperTiny = "whisper-tiny"
  case whisperBase = "whisper-base"
  case whisperSmall = "whisper-small"
  case whisperMedium = "whisper-medium"
  case whisperLarge = "whisper-large"
  /// large-v3-turbo (the 2024-09-30 release): large-v3's encoder with a 4-layer decoder.
  case whisperLargeTurbo = "whisper-large-turbo"
  /// NVIDIA Parakeet TDT 0.6B v3 retrained by Moondream ("Ultra"), plus the CTC model the
  /// Glossary uses. 25 European languages. See `ParakeetBackend`.
  case parakeetUltra = "parakeet-ultra"

  var engine: OfflineEngine {
    switch self {
    case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge, .whisperLargeTurbo:
      return .whisperKit
    case .parakeetUltra:
      return .parakeet
    }
  }

  var displayName: String {
    switch self {
    case .whisperTiny: return "Whisper Tiny"
    case .whisperBase: return "Whisper Base"
    case .whisperSmall: return "Whisper Small"
    case .whisperMedium: return "Whisper Medium"
    case .whisperLarge: return "Whisper Large"
    case .whisperLargeTurbo: return "Whisper Large v3 Turbo"
    case .parakeetUltra: return "Parakeet Ultra"
    }
  }
  
  var estimatedSizeMB: Int {
    switch self {
    case .whisperTiny: return 75
    case .whisperBase: return 140
    case .whisperSmall: return 460
    case .whisperMedium: return 1500
    case .whisperLarge: return 3000  // full large-v3 ~3 GB; compressed variant exists at ~947 MB
    case .whisperLargeTurbo: return 1600  // full turbo ~1.6 GB; compressed variant exists at ~632 MB
    case .parakeetUltra: return 700  // Ultra ~603 MB + CTC 110M ~98 MB, measured on disk
    }
  }
  
  /// The model the list recommends: the one a user who does not want to research model sizes
  /// should take. That is Parakeet Ultra since 2026-09-29 — turbo's accuracy on real German
  /// dictation (8.1 % vs 8.4 % WER) at ~1/20 of the wait and under half the download
  /// (`benchmarks/local-asr/README.md`). Magnus after dictating with it: „Das ist viel, viel besser als
  /// Whisper Large."
  /// Turbo held the star before; Base before that.
  var isRecommended: Bool {
    return self == .parakeetUltra
  }

  /// Shown instead of the star on the model that is merely the fastest way to *try* offline
  /// dictation. Keeps Base findable for a metered connection without implying it is the best pick.
  var isQuickStart: Bool {
    return self == .whisperBase
  }

  /// Superseded by turbo and no longer offered.
  ///
  /// Medium is the same download size as turbo while being clearly less accurate, and large-v3 is
  /// twice the download and several times slower for the same transcript. Neither has a case where
  /// it is the better pick, and a six-entry list where two entries are traps is worse than a
  /// four-entry list. They stay in the enum — a user who already downloaded one keeps using it,
  /// keeps seeing it in the list, and can delete it to get the disk space back.
  var isSuperseded: Bool {
    switch self {
    case .whisperMedium, .whisperLarge: return true
    case .whisperTiny, .whisperBase, .whisperSmall, .whisperLargeTurbo, .parakeetUltra: return false
    }
  }

  /// What the model list offers: everything current, plus any superseded model still on disk.
  static var offerable: [OfflineModelType] {
    allCases.filter { !$0.isSuperseded || ModelManager.shared.isModelAvailable($0) }
  }

  /// Whether this model's encoder may go to the Neural Engine.
  ///
  /// It may not, for the large models. WhisperKit defaults the audio encoder to
  /// `.cpuAndNeuralEngine`, which makes CoreML compile the model for the ANE the first time it is
  /// loaded — and for large-v3-turbo that compile is *pathological*: measured 2026-08-31,
  /// `ANECompilerService` sat at 100 % CPU for over 14 minutes without finishing, across nine load
  /// attempts, none of which ever reported a loaded model. On the GPU the same model loads in
  /// seconds with no compile step at all.
  ///
  /// The small models compile in moments and keep the ANE, where it costs less power. Parakeet is
  /// built for the ANE (FluidAudio's default placement) and its load comes from the compile cache.
  var usesNeuralEngine: Bool {
    switch self {
    case .whisperTiny, .whisperBase, .parakeetUltra: return true
    case .whisperSmall, .whisperMedium, .whisperLarge, .whisperLargeTurbo: return false
    }
  }

  /// Offline models ordered worst to best pick. Used to choose a sensible model on this Mac
  /// without asking the user which size means what — Offline Mode walks it from the end.
  /// Parakeet Ultra last: it ties turbo on accuracy and is ~20× faster.
  static var byAccuracy: [OfflineModelType] {
    [.whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge, .whisperLargeTurbo, .parakeetUltra]
  }

  /// The on-device model Offline Mode picks when none is downloaded yet (D1 in
  /// `plans/active/parakeet-offline.md`: new setups get Parakeet; nobody is switched silently).
  static var mostAccurate: OfflineModelType { .parakeetUltra }
  
  // Map to WhisperKit model name (HuggingFace: openai_whisper-{name}); nil for other engines.
  var whisperKitModelName: String? {
    switch self {
    case .whisperTiny: return "tiny"
    case .whisperBase: return "base"
    case .whisperSmall: return "small"
    case .whisperMedium: return "medium"
    case .whisperLarge: return "large-v3"
    // The HuggingFace repo (argmaxinc/whisperkit-coreml) names turbo by its release date;
    // `large-v3_turbo` there is the older v2-era conversion, so the dated variant is the one
    // that corresponds to OpenAI's large-v3-turbo.
    case .whisperLargeTurbo: return "large-v3-v20240930_turbo"
    case .parakeetUltra: return nil
    }
  }
}

// MARK: - Model Manager

/// Offline speech models: WhisperKit's CoreML bundles under `Application Support/WhisperKit`, and
/// Parakeet under FluidAudio's own directory (`ParakeetBackend.modelsRoot`).
///
/// Everything about downloads, cancellation, readiness and deletion is `ModelStore`; this class
/// only knows each engine's folder layout, what makes a download complete, and that loading means
/// `LocalSpeechService`.
final class ModelManager: ModelStore<OfflineModelType> {
  static let shared = ModelManager()

  private init() {
    super.init(logPrefix: "MODEL-MANAGER")
  }

  // MARK: - Paths

  override nonisolated var rootDirectory: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent("WhisperKit")
  }

  /// `models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>` — WhisperKit's own layout.
  private nonisolated var whisperKitRepoDirectory: URL {
    rootDirectory
      .appendingPathComponent("models")
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
  }

  override nonisolated func resolveModelPath(for type: OfflineModelType) -> URL? {
    guard let whisperKitModelName = type.whisperKitModelName else {
      // Parakeet: the folder holding both of its models. Resolves while partial too, so Delete
      // can clear an interrupted download; completeness is `isModelAvailable`'s job.
      let root = ParakeetBackend.modelsRoot
      return fileManager.fileExists(atPath: root.path) ? root : nil
    }
    // Standard WhisperKit download structure first.
    let nestedPath = whisperKitRepoDirectory
      .appendingPathComponent("openai_whisper-\(whisperKitModelName)")
    if fileManager.fileExists(atPath: nestedPath.path) {
      return nestedPath
    }

    // Simple location (legacy/manual downloads).
    let possibleSimpleNames = [
      "openai_whisper-\(whisperKitModelName)",
      "\(whisperKitModelName)",
      "whisper-\(whisperKitModelName)"
    ]
    for name in possibleSimpleNames {
      let path = rootDirectory.appendingPathComponent(name)
      if fileManager.fileExists(atPath: path.path) {
        return path
      }
    }
    return nil
  }

  // MARK: - Model Availability

  /// Returns true only when the model folder exists and contains required WhisperKit files
  /// (e.g. AudioEncoder.mlmodelc). Avoids showing incomplete downloads as "available".
  override nonisolated func isModelAvailable(_ type: OfflineModelType) -> Bool {
    if type.engine == .parakeet {
      return ParakeetBackend.isDownloaded
    }
    guard let modelPath = resolveModelPath(for: type) else {
      DebugLogger.logDebug("MODEL-MANAGER: Checking availability for \(type.displayName)")
      DebugLogger.logDebug("MODEL-MANAGER: WhisperKit directory: \(rootDirectory.path)")
      if fileManager.fileExists(atPath: rootDirectory.path),
         let contents = try? fileManager.contentsOfDirectory(atPath: rootDirectory.path) {
        DebugLogger.logDebug("MODEL-MANAGER: WhisperKit directory contents: \(contents.joined(separator: ", "))")
      }
      return false
    }
    if let missing = Self.incompleteComponent(at: modelPath) {
      DebugLogger.logDebug(
        "MODEL-MANAGER: \(type.displayName) folder exists but \(missing) is missing or empty — download incomplete")
      return false
    }
    DebugLogger.logDebug("MODEL-MANAGER: Found \(type.displayName) at: \(modelPath.path)")
    return true
  }

  /// The compiled CoreML components WhisperKit loads. Checking only `AudioEncoder.mlmodelc` (what
  /// this did before) reported a half-finished download as ready: the 2026-08-31 case got as far
  /// as recording, then failed inside WhisperKit with "Unable to load model …
  /// TextDecoderContextPrefill.mlmodelc", which the error mapping turned into a "Model Not
  /// Downloaded" popup for a model the UI was showing as downloaded.
  ///
  /// `TextDecoderContextPrefill` is deliberately NOT required: it is the prefill cache, and not
  /// every variant in the repo ships it. A model missing it still loads on most paths, and the
  /// case where it does not is handled by the self-heal in `ensureReady` rather than by declaring
  /// every such model unavailable. Present but half-written is the 08-31 case — Hub creates the
  /// `.mlmodelc` directory before moving compiled files into it, so an interrupted download
  /// leaves that folder in place with no loadable model inside.
  private static let requiredComponents = [
    "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc",
  ]

  static let optionalComponents = ["TextDecoderContextPrefill.mlmodelc"]

  static let compiledModelFiles = ["coremldata.bin", "model.mil", "weights/weight.bin"]

  /// First missing `<component>/<file>` under `modelPath`, or nil when the folder is loadable.
  /// Direct children only — WhisperKit loads `modelFolder/<component>` itself, so a nested
  /// match was never loadable. A required component must be a complete compiled model; an
  /// optional one must be complete only when its directory exists.
  nonisolated static func incompleteComponent(at modelPath: URL) -> String? {
    for component in requiredComponents {
      if let missing = firstMissingCompiledFile(in: component, at: modelPath) {
        return missing
      }
    }
    for component in optionalComponents {
      let componentURL = modelPath.appendingPathComponent(component)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: componentURL.path, isDirectory: &isDirectory) else {
        continue
      }
      if let missing = firstMissingCompiledFile(in: component, at: modelPath) {
        return missing
      }
    }
    return nil
  }

  /// A component is complete when `modelPath/<component>` is a directory and each compiled
  /// model file is a regular file with size > 0. Missing directory or empty file → that path.
  private nonisolated static func firstMissingCompiledFile(in component: String, at modelPath: URL) -> String? {
    let fileManager = FileManager.default
    let componentURL = modelPath.appendingPathComponent(component)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: componentURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      return "\(component)/\(compiledModelFiles[0])"
    }
    for file in compiledModelFiles {
      let fileURL = file.split(separator: "/").reduce(componentURL) {
        $0.appendingPathComponent(String($1))
      }
      var isFileDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isFileDirectory),
            !isFileDirectory.boolValue,
            let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let size = attrs[.size] as? NSNumber,
            size.int64Value > 0 else {
        return "\(component)/\(file)"
      }
    }
    return nil
  }

  // MARK: - Ready to use

  /// The wait after a download is CoreML compiling the model for the Neural Engine. It happens
  /// once per model and is minutes for the large ones, so it is worth naming rather than showing
  /// a spinner that looks stuck.
  override func preparingMessage(for type: OfflineModelType) -> String {
    // Parakeet's first load (ANE compile included) measured 0.5 s — the generic line fits.
    if type.engine == .parakeet { return super.preparingMessage(for: type) }
    return "Preparing \(type.displayName) for this Mac — one-time step, can take a few minutes."
  }

  /// Load failure after the folder looked complete is the verified-corrupt case — purge and
  /// fetch once more, because the user is waiting on a dictation.
  override var healsCorruptDownloadOnLoadFailure: Bool { true }

  override func load(_ type: OfflineModelType) async throws {
    try await LocalSpeechService.shared.initializeModel(type)
  }

  override func unload(_ type: OfflineModelType) async {
    guard await LocalSpeechService.shared.isLoaded(modelType: type) else { return }
    await LocalSpeechService.shared.unloadModel()
  }

  // MARK: - Download

  override func fetch(_ type: OfflineModelType, onProgress: @escaping (Double) -> Void) async throws {
    guard let whisperKitModelName = type.whisperKitModelName else {
      try await fetchParakeet(onProgress: onProgress)
      return
    }
    try? fileManager.createDirectory(at: whisperKitRepoDirectory, withIntermediateDirectories: true)
    let modelName = "openai_whisper-\(whisperKitModelName)"

    do {
      let downloadedModelPath = try await WhisperKit.download(
        variant: modelName,
        downloadBase: rootDirectory,
        progressCallback: { progress in onProgress(progress.fractionCompleted) }
      )
      DebugLogger.log("MODEL-MANAGER: Download completed to: \(downloadedModelPath.path)")

      if !isModelAvailable(type) {
        logDirectoryContents(rootDirectory)
        throw ModelStoreError.downloadFailed("Model downloaded but not properly available. Please try downloading again.")
      }
    } catch let error as ModelStoreError {
      throw error
    } catch {
      if Self.isCancellation(error) { throw CancellationError() }
      let errorMessage = error.localizedDescription
      DebugLogger.logError("MODEL-MANAGER: WhisperKit error: \(errorMessage)")

      // Missing required model files mean an incomplete or corrupted download.
      if errorMessage.contains("MelSpectrogram.mlmodelc") {
        DebugLogger.logError("MODEL-MANAGER: MelSpectrogram.mlmodelc missing - this indicates an incomplete download")
        logDirectoryContents(rootDirectory)
        throw ModelStoreError.downloadFailed(
          "Model download appears incomplete. The MelSpectrogram.mlmodelc file is missing. " +
          "This usually means the download was interrupted or failed. " +
          "Please try downloading again. If the problem persists, try deleting any partial downloads first."
        )
      }
      if errorMessage.contains("AudioEncoder.mlmodelc") {
        DebugLogger.logError("MODEL-MANAGER: AudioEncoder.mlmodelc missing - model folder incomplete or corrupted")
        logDirectoryContents(rootDirectory)
        throw ModelStoreError.downloadFailed(
          "Model folder exists but AudioEncoder.mlmodelc is missing (incomplete or corrupted). " +
          "In Settings, delete the model and download it again."
        )
      }

      let nsError = error as NSError
      DebugLogger.logError("MODEL-MANAGER: Error domain: \(nsError.domain), code: \(nsError.code)")
      DebugLogger.logError("MODEL-MANAGER: Error userInfo: \(nsError.userInfo)")
      throw ModelStoreError.downloadFailed("Failed to download WhisperKit model: \(errorMessage)")
    }
  }

  /// FluidAudio fetches from HuggingFace with its own URLSession — like WhisperKit's, not wrapped
  /// by the Offline Mode guard, and like it carrying nothing of the user's.
  private func fetchParakeet(onProgress: @escaping (Double) -> Void) async throws {
    do {
      // `ModelStore.performDownload` hops every progress call to the main actor itself.
      try await ParakeetBackend.download { fraction in onProgress(fraction) }
    } catch {
      if Self.isCancellation(error) { throw CancellationError() }
      DebugLogger.logError("MODEL-MANAGER: Parakeet download failed: \(error.localizedDescription)")
      logDirectoryContents(ParakeetBackend.modelsRoot)
      throw ModelStoreError.downloadFailed("Failed to download Parakeet Ultra: \(error.localizedDescription)")
    }
  }

  // MARK: - Log Directory Contents (for debugging)
  private nonisolated func logDirectoryContents(_ directory: URL) {
    DebugLogger.log("MODEL-MANAGER: Listing contents of \(directory.path)")

    guard fileManager.fileExists(atPath: directory.path) else {
      DebugLogger.log("MODEL-MANAGER: Directory does not exist")
      return
    }

    if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) {
      DebugLogger.log("MODEL-MANAGER: Directory contents: \(contents.joined(separator: ", "))")

      // Also check subdirectories
      for item in contents {
        let itemPath = directory.appendingPathComponent(item)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: itemPath.path, isDirectory: &isDirectory) && isDirectory.boolValue {
          if let subContents = try? fileManager.contentsOfDirectory(atPath: itemPath.path) {
            DebugLogger.log("MODEL-MANAGER: \(item)/ contents: \(subContents.prefix(20).joined(separator: ", "))")
          }
        }
      }
    } else {
      DebugLogger.log("MODEL-MANAGER: Could not read directory contents")
    }
  }
}
