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

/// Same load path `ParakeetEngine` uses: an exact folder when one is given, otherwise the
/// version's own cache. `AsrModels.load(from:version:)` would resolve a sibling repo folder
/// and can silently pick stock v3.
func loadParakeetModels(version: AsrModelVersion, localDirectory: URL?) async throws -> AsrModels {
  if let localDirectory {
    return try AsrModels.loadLocal(from: localDirectory, version: version)
  }
  return try await AsrModels.downloadAndLoad(version: version)
}

/// 80 ms at 16 kHz. Streaming engines feed this size so a step matches one encoder frame.
let streamingFrameSamples = 1280

func pcm16kMono(_ samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
  let count = samples.count
  guard count > 0,
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
    let channel = buffer.floatChannelData
  else {
    throw NSError(domain: "bench", code: 5, userInfo: [
      NSLocalizedDescriptionKey: "Could not build a 16 kHz mono buffer"
    ])
  }
  buffer.frameLength = AVAudioFrameCount(count)
  samples.withUnsafeBufferPointer { source in
    channel[0].update(from: source.baseAddress!, count: count)
  }
  return buffer
}

/// Per-word emission lag (seconds) from the streaming engines. `main` prints and clears it
/// after each streaming engine.
enum StreamLagCollector {
  static var lags: [Double] = []

  static func append(_ values: [Double]) {
    lags.append(contentsOf: values)
  }
}

final class ParakeetEngine: Engine {
  let name: String
  private let version: AsrModelVersion
  private let useVocabulary: Bool
  /// Exact model folder. `AsrModels.load(from:version:)` would resolve
  /// `<parent>/<version.repo.folderName>` and silently load stock v3.
  private let localDirectory: URL?
  private let boostConfig: VocabularyRescorer.Config?
  /// When true, vocabulary replacements go through the app's guard
  /// (`ParakeetVocabularyGuard`) instead of FluidAudio's rewritten text.
  private let appGuard: Bool
  private var manager: AsrManager?
  private var ctcModels: CtcModels?
  /// Boosting sessions are built per vocabulary (tokenising the terms is not free), and the two
  /// datasets use different vocabularies.
  private var boosting: [String: VocabularyBoostingSession] = [:]
  private let converter = AudioConverter()

  init(
    version: AsrModelVersion, label: String, useVocabulary: Bool, localDirectory: URL? = nil,
    boostConfig: VocabularyRescorer.Config? = nil, nameOverride: String? = nil,
    appGuard: Bool = false
  ) {
    self.version = version
    self.useVocabulary = useVocabulary
    self.localDirectory = localDirectory
    self.boostConfig = boostConfig
    self.appGuard = appGuard
    self.name = nameOverride ?? ("parakeet-\(label)" + (useVocabulary ? "+vocab" : ""))
  }

  func load() async throws {
    let models = try await loadParakeetModels(version: version, localDirectory: localDirectory)
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
      session = try await VocabularyBoostingSession(
        vocabulary: context, ctcModels: ctcModels, config: boostConfig)
      boosting[key] = session
    }
    let rescored = await session.rescore(
      text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
    guard appGuard else { return rescored?.text ?? result.text }
    // Same order as ParakeetBackend.VocabularyBooster.rescore: accept only
    // shouldReplace hits that name a term, then the app guard, then casing.
    guard let rescored, rescored.wasModified else {
      return ParakeetVocabularyGuard.restoreGlossaryCasing(
        in: result.text, glossaryTerms: vocabulary)
    }
    let candidates = rescored.replacements.filter(\.shouldReplace).compactMap {
      replacement -> ParakeetVocabularyGuard.Replacement? in
      guard let term = replacement.replacementWord else { return nil }
      return ParakeetVocabularyGuard.Replacement(
        originalSpan: replacement.originalWord, term: term)
    }
    let applied = ParakeetVocabularyGuard.apply(
      to: result.text, replacements: candidates, glossaryTerms: vocabulary)
    return ParakeetVocabularyGuard.restoreGlossaryCasing(
      in: applied.text, glossaryTerms: vocabulary)
  }

  func unload() async {
    await manager?.cleanup()
    manager = nil
    ctcModels = nil
    boosting = [:]
  }
}

// MARK: - Nemotron Unified (FluidAudio offline batch, German prompt)

/// Offline 15 s-window Nemotron. Vocabulary boosting, when on, is configured on the manager
/// (its default rescorer config is the ITN one) and reused until the term list changes.
final class NemotronUnifiedEngine: Engine {
  let name: String
  private let useVocabulary: Bool
  private var manager: UnifiedAsrManager?
  private var ctcModels: CtcModels?
  /// Joined term list last passed to `configureVocabularyBoosting`. Nil until the first non-empty list.
  private var configuredVocabularyKey: String?
  private let converter = AudioConverter()

  init(useVocabulary: Bool) {
    self.useVocabulary = useVocabulary
    self.name = "nemotron-unified" + (useVocabulary ? "+vocab" : "")
  }

  func load() async throws {
    let manager = UnifiedAsrManager(config: UnifiedConfig(family: .nemotronMultilingual(.de)))
    try await manager.loadModels()
    self.manager = manager
    if useVocabulary {
      ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
    }
  }

  func transcribe(_ clip: Clip, vocabulary: [String], rawGlossary: String) async throws -> String {
    guard let manager else { throw NSError(domain: "bench", code: 3) }
    let samples = try converter.resampleAudioFile(clip.url)
    if useVocabulary, let ctcModels, !vocabulary.isEmpty {
      let key = vocabulary.joined(separator: "\u{1F}")
      if configuredVocabularyKey != key {
        let context = CustomVocabularyContext(terms: vocabulary.map { CustomVocabularyTerm(text: $0) })
        try await manager.configureVocabularyBoosting(vocabulary: context, ctcModels: ctcModels)
        configuredVocabularyKey = key
      }
    }
    return try await manager.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func unload() async {
    await manager?.cleanup()
    manager = nil
    ctcModels = nil
    configuredVocabularyKey = nil
  }
}

// MARK: - Nemotron streaming (FluidAudio, chunked-attention windows)

/// Streaming Nemotron. Vocabulary is ignored. Each clip is reset, then pushed as fast as the
/// encoder will take it in 80 ms frames. Word lag is `fedSeconds` at the partial where the word
/// first appeared, minus that word's end time from `consumeWordTimings()`.
final class NemotronStreamingEngine: Engine {
  let name: String
  private let config: UnifiedConfig
  private var manager: StreamingUnifiedAsrManager?
  private let converter = AudioConverter()

  init(leftFrames: Int, chunkFrames: Int, rightFrames: Int) {
    let config = UnifiedConfig(
      leftFrames: leftFrames, chunkFrames: chunkFrames, rightFrames: rightFrames,
      family: .nemotronMultilingual(.de))
    self.config = config
    // latencyMs is (chunk + right) × 80 ms: 2080, 1120, 560 for the shipped contexts.
    self.name = "nemotron-stream-\(config.latencyMs)"
  }

  func load() async throws {
    let manager = StreamingUnifiedAsrManager(config: config, encoderPrecision: .int8)
    try await manager.loadModels()
    self.manager = manager
  }

  func transcribe(_ clip: Clip, vocabulary: [String], rawGlossary: String) async throws -> String {
    guard let manager else { throw NSError(domain: "bench", code: 3) }
    try await manager.reset()
    let samples = try converter.resampleAudioFile(clip.url)
    var fedSeconds = 0.0
    var emissionTimes: [Double] = []
    var offset = 0
    while offset < samples.count {
      let count = min(streamingFrameSamples, samples.count - offset)
      let buffer = try pcm16kMono(samples[offset..<(offset + count)])
      try await manager.appendAudio(buffer)
      try await manager.processBufferedAudio()
      offset += count
      fedSeconds += Double(count) / 16_000
      recordNewWords(await manager.getPartialTranscript(), at: fedSeconds, into: &emissionTimes)
    }
    let text = try await manager.finish()
    recordNewWords(text, at: fedSeconds, into: &emissionTimes)
    let timings = await manager.consumeWordTimings()
    StreamLagCollector.append(wordLags(emissions: emissionTimes, ends: timings.map(\.endTime)))
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func unload() async {
    await manager?.cleanup()
    manager = nil
  }

  /// Words that showed up since the previous partial. Earlier words keep the time they first appeared.
  private func recordNewWords(_ transcript: String, at fedSeconds: Double, into emissions: inout [Double]) {
    let count = transcript.split(whereSeparator: \.isWhitespace).count
    guard count > emissions.count else { return }
    emissions.append(contentsOf: repeatElement(fedSeconds, count: count - emissions.count))
  }

  /// Index-aligned lag. The clip is dropped when the two word counts differ by more than 20 %.
  private func wordLags(emissions: [Double], ends: [TimeInterval]) -> [Double] {
    let peak = max(emissions.count, ends.count)
    guard peak > 0 else { return [] }
    if Double(abs(emissions.count - ends.count)) / Double(peak) > 0.20 { return [] }
    return (0..<min(emissions.count, ends.count)).map { index in
      emissions[index] - ends[index]
    }
  }
}

// MARK: - Parakeet Ultra sliding window

/// Ultra through `SlidingWindowAsrManager`. The input stream is single-shot (`finish` closes it),
/// so each clip builds a new manager around the models loaded once in `load()`.
final class ParakeetSlidingWindowEngine: Engine {
  let name = "parakeet-ultra-sliding"
  private var models: AsrModels?
  private let converter = AudioConverter()

  func load() async throws {
    models = try await loadParakeetModels(version: .ultra, localDirectory: nil)
  }

  func transcribe(_ clip: Clip, vocabulary: [String], rawGlossary: String) async throws -> String {
    guard let models else { throw NSError(domain: "bench", code: 3) }
    // `.system` is the non-microphone source. `.microphone` is the only other case.
    let manager = SlidingWindowAsrManager(config: .streaming.applying(language: .german))
    try await manager.loadModels(models)
    try await manager.startStreaming(source: .system)
    let samples = try converter.resampleAudioFile(clip.url)
    var offset = 0
    while offset < samples.count {
      let count = min(streamingFrameSamples, samples.count - offset)
      let buffer = try pcm16kMono(samples[offset..<(offset + count)])
      await manager.streamAudio(buffer)
      offset += count
    }
    let text = try await manager.finish()
    await manager.cleanup()
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func unload() async {
    models = nil
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
