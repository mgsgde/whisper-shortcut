import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Speech
import WhisperKit

/// One offline speech-to-text candidate. `vocabulary` is the glossary for engines that take one;
/// engines without a biasing mechanism ignore it (their `+glossary` twin does not exist).
protocol Engine: AnyObject {
  var name: String { get }
  /// Everything that happens once per process: weights to memory, compile, asset install.
  func load() async throws
  func transcribe(_ clip: Clip, vocabulary: [String], rawGlossary: String) async throws -> String
  func unload() async
}

// MARK: - Whisper (WhisperKit, the app's current engine)

/// Configured as `LocalSpeechService` does: encoder and decoder on the GPU for large models,
/// language pinned to German, two temperature fallbacks, the glossary as `promptTokens`, and the
/// empty-result retry without prompt.
final class WhisperEngine: Engine {
  let name: String
  private let variant: String
  private let useGlossary: Bool
  private var kit: WhisperKit?

  init(variant: String, useGlossary: Bool) {
    self.variant = variant
    self.useGlossary = useGlossary
    self.name = "whisper-\(variant == "large-v3-v20240930_turbo" ? "turbo" : variant)" + (useGlossary ? "+glossary" : "")
  }

  func load() async throws {
    let folder = Datasets.userContextDir.deletingLastPathComponent()
      .appendingPathComponent("WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)")
    guard FileManager.default.fileExists(atPath: folder.path) else {
      throw NSError(domain: "bench", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Whisper \(variant) is not downloaded in the app (\(folder.path))"
      ])
    }
    let onANE = variant == "tiny" || variant == "base"
    let units: MLComputeUnits = onANE ? .cpuAndNeuralEngine : .cpuAndGPU
    let config = WhisperKitConfig(
      modelFolder: folder.path,
      computeOptions: ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: units, textDecoderCompute: units),
      verbose: false, logLevel: .none, prewarm: false, load: true, download: false)
    kit = try await WhisperKit(config)
  }

  func transcribe(_ clip: Clip, vocabulary: [String], rawGlossary: String) async throws -> String {
    guard let kit else { throw NSError(domain: "bench", code: 3) }
    var promptTokens: [Int]?
    if useGlossary, let tokenizer = kit.tokenizer {
      // The app conditions on the raw section text; the synthetic set has no user glossary, so
      // it gets its term list in the same "Terms: a, b" shape.
      let text = clip.dataset == "real" ? rawGlossary : "Terms: " + vocabulary.joined(separator: ", ")
      let cleaned = text.filter { !"()\"'„“”".contains($0) }
      let encoded = tokenizer.encode(text: cleaned).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
      promptTokens = Array(encoded.prefix(224))
    }
    func options(_ prompt: [Int]?) -> DecodingOptions {
      DecodingOptions(language: "de", temperatureFallbackCount: 2, skipSpecialTokens: true, promptTokens: prompt)
    }
    var results = try await kit.transcribe(audioPath: clip.url.path, decodeOptions: options(promptTokens))
    var text = results.map(\.text).joined(separator: " ")
    if promptTokens != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      results = try await kit.transcribe(audioPath: clip.url.path, decodeOptions: options(nil))
      text = results.map(\.text).joined(separator: " ")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func unload() async {
    await kit?.unloadModels()
    kit = nil
  }
}

// MARK: - Parakeet family (FluidAudio, CoreML on the ANE)

final class ParakeetEngine: Engine {
  let name: String
  private let version: AsrModelVersion
  private let useVocabulary: Bool
  private var manager: AsrManager?
  private var ctcModels: CtcModels?
  /// Boosting sessions are built per vocabulary (tokenising the terms is not free), and the two
  /// datasets use different vocabularies.
  private var boosting: [String: VocabularyBoostingSession] = [:]
  private let converter = AudioConverter()

  init(version: AsrModelVersion, label: String, useVocabulary: Bool) {
    self.version = version
    self.useVocabulary = useVocabulary
    self.name = "parakeet-\(label)" + (useVocabulary ? "+vocab" : "")
  }

  func load() async throws {
    let models = try await AsrModels.downloadAndLoad(version: version)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    self.manager = manager
    if useVocabulary {
      ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
    }
  }

  func transcribe(_ clip: Clip, vocabulary: [String], rawGlossary: String) async throws -> String {
    guard let manager else { throw NSError(domain: "bench", code: 3) }
    var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
    guard useVocabulary, let ctcModels, !vocabulary.isEmpty else {
      return try await manager.transcribe(clip.url, decoderState: &state, language: .german).text
    }
    // The boosted path needs the samples for the CTC spotter anyway, so it decodes from them
    // rather than reading the file twice.
    let samples = try converter.resampleAudioFile(clip.url)
    let result = try await manager.transcribe(samples, decoderState: &state, language: .german)
    let key = vocabulary.joined(separator: "\u{1F}")
    let session: VocabularyBoostingSession
    if let cached = boosting[key] {
      session = cached
    } else {
      let context = CustomVocabularyContext(terms: vocabulary.map { CustomVocabularyTerm(text: $0) })
      session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels)
      boosting[key] = session
    }
    let rescored = await session.rescore(
      text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
    return rescored?.text ?? result.text
  }

  func unload() async {
    await manager?.cleanup()
    manager = nil
    ctcModels = nil
    boosting = [:]
  }
}

// MARK: - Apple SpeechAnalyzer (macOS 26, system model, nothing to ship)

@available(macOS 26.0, *)
final class AppleSpeechEngine: Engine {
  let name: String
  private let useContext: Bool
  private let locale = Locale(identifier: "de_DE")

  init(useContext: Bool) {
    self.useContext = useContext
    self.name = "apple-speechanalyzer" + (useContext ? "+ctx" : "")
  }

  func load() async throws {
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
      throw NSError(domain: "bench", code: 4, userInfo: [NSLocalizedDescriptionKey: "de_DE not supported by SpeechTranscriber"])
    }
    let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
  }

  func transcribe(_ clip: Clip, vocabulary: [String], rawGlossary: String) async throws -> String {
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
    if useContext, !vocabulary.isEmpty {
      let context = AnalysisContext()
      context.contextualStrings[.general] = vocabulary
      try await analyzer.setContext(context)
    }
    let collector = Task { () -> String in
      var parts: [String] = []
      for try await result in transcriber.results where result.isFinal {
        parts.append(String(result.text.characters))
      }
      return parts.joined(separator: " ")
    }
    let file = try AVAudioFile(forReading: clip.url)
    if let end = try await analyzer.analyzeSequence(from: file) {
      try await analyzer.finalizeAndFinish(through: end)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func unload() async {}
}
