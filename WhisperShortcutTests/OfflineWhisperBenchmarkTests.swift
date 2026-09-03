import Testing
import Foundation
import AVFoundation
import WhisperKit
@testable import WhisperShortcut_AppStore

/// Slice 4's gate from `plans/active/streaming-dictate.md`: is offline Whisper's decode fast
/// enough, relative to the speech it decodes, that transcribing chunks *while the user is still
/// talking* can keep up? Streaming only pays off when the realtime factor is far below 1; near 1
/// the in-flight chunks queue up behind the speech and streaming makes the wait worse.
///
/// The measurement has to be deliberate rather than passive: nobody here dictates offline day to
/// day, so there is no real usage to mine, and the numbers belong to the Mac they were taken on —
/// the machine that matters is the one the app is deployed to.
///
/// Opt-in via `WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER=1`. It loads ~1.6 GB and takes minutes, which
/// is exactly what `run-tests.sh` must never do — `/release` gates on that suite.
///
/// **Passing the flag on the command line does not work** (corrected 2026-09-02, after three runs
/// that reported "0 tests" and passed in 0.001 s). Neither a plain export nor the
/// `TEST_RUNNER_`-prefixed twin reaches this sandboxed macOS test host; the prefix is a
/// simulator-runner mechanism. The variable has to come from the **test plan**, and the
/// `-only-testing` selector needs the trailing `()` that Swift Testing function IDs carry —
/// without it nothing matches and the run still reports success:
///
///     # 1. add the variable to the plan's configuration options
///     #    ("environmentVariableEntries": [{"key": "WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER",
///     #                                     "value": "1"}])
///     # 2. run, and restore the plan afterwards — it is checked in
///     xcodebuild test -scheme WhisperShortcut-AppStore -testPlan WhisperShortcut-AppStore \
///       -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-tests \
///       -skipPackagePluginValidation -skipMacroValidation \
///       '-only-testing:WhisperShortcutTests/OfflineWhisperBenchmarkTests/realtimeFactor()'
///
/// A run reporting "0 tests in 1 suite passed" is that mistake, not a green benchmark.
///
/// Baseline, M1 Pro / 16 GB, Turbo, 2026-09-02: cold load 3.7–6.1 s; decode ~12 ms per output
/// character (4.25 s for 24.5 s of speech, 12.66 s for 68 s), i.e. rtf ≈ 0.18 on dense speech; the
/// first decode after every load costs ~3 s extra.
///
/// What is measured:
///   - **load**: weights from disk into RAM, the cost `ConnectionPrewarmer.warmOfflineWhisper`
///     moves off the post-Stop critical path and into the recording window
///   - **decode**: `LocalSpeechService.transcribe` end to end, per audio length
///   - **rtf**: decode ÷ audio duration — the streaming gate
///
/// Speech comes from `say` rather than a fixture: it keeps the repo free of binary audio, and the
/// decode cost tracks duration and speech density, not recording quality.
@Suite("Offline Whisper benchmark (opt-in)", .tags(.liveNetwork), .enabled(if: !TestRun.isHermetic))
struct OfflineWhisperBenchmarkTests {

  private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER"] == "1"
  }

  /// Overridable so the same three dictations can be run against tiny/base/small too — the
  /// interesting comparison for a machine where Turbo turns out to be too slow.
  private static var modelType: OfflineModelType {
    ProcessInfo.processInfo.environment["WHISPERSHORTCUT_BENCH_OFFLINE_MODEL"]
      .flatMap(OfflineModelType.init(rawValue:)) ?? .whisperLargeTurbo
  }

  /// German medical-practice dictation, because that is the deployment this was measured for:
  /// domain nouns and numbers, the material Whisper is slowest and least accurate on.
  private static let sentences = [
    "Der Patient klagt seit drei Tagen über ziehende Beschwerden im rechten Oberbauch.",
    "Die körperliche Untersuchung zeigt einen weichen Bauch ohne Abwehrspannung.",
    "Der Blutdruck beträgt einhundertdreißig zu fünfundachtzig, der Puls ist regelmäßig.",
    "Im Labor sind die Entzündungswerte leicht erhöht, das Blutbild ist unauffällig.",
    "Die Sonographie des Abdomens ergibt keinen Hinweis auf Gallensteine.",
    "Wir vereinbaren eine Kontrolle in zwei Wochen und besprechen die Befunde erneut.",
    "Der Patient nimmt weiterhin Ramipril fünf Milligramm einmal täglich ein.",
  ]

  /// One `say` run per target length. The voice is fixed so repeated runs on different Macs
  /// compare like with like.
  private static func makeSpeech(sentenceCount: Int, at url: URL, startingAt offset: Int = 0) throws {
    let text = (0..<sentenceCount).map { sentences[($0 + offset) % sentences.count] }
      .joined(separator: " ")
    try makeSpeech(text: text, at: url)
  }

  private static func makeSpeech(text: String, at url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = [
      "-v", "Anna", "-o", url.path, "--data-format=LEI16@16000", text,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "OfflineWhisperBenchmark", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "`say` failed"])
    }
  }

  private static func duration(of url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.fileFormat.sampleRate
  }

  @Test(
    "Realtime factor across dictation lengths",
    .enabled(if: isEnabled, "Set WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER=1 to run (loads ~1.6 GB)")
  )
  func realtimeFactor() async throws {
    let type = Self.modelType
    #expect(ModelManager.shared.isModelAvailable(type), "Download \(type.displayName) first")

    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("offline-whisper-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    // Cold on purpose: this is the load a Praxis pays on the first dictation after every pause
    // longer than `LocalSpeechService.idleUnloadAfter`.
    await LocalSpeechService.shared.unloadModel()
    let loadStart = CFAbsoluteTimeGetCurrent()
    try await LocalSpeechService.shared.initializeModel(type)
    let load = CFAbsoluteTimeGetCurrent() - loadStart

    print("BENCH-OFFLINE model=\(type.rawValue) coldLoadS=\(String(format: "%.2f", load))")

    // ~5 s, ~20 s, ~60 s: the lengths the plan's manual verification uses, plus a repeat of the
    // middle one to show run-to-run spread before anyone reads a single number as a constant.
    for (label, sentenceCount) in [("short", 1), ("medium", 5), ("long", 14), ("medium-again", 5)] {
      let audioURL = workDir.appendingPathComponent("\(label).wav")
      try Self.makeSpeech(sentenceCount: sentenceCount, at: audioURL)
      let audioSeconds = try Self.duration(of: audioURL)

      let decodeStart = CFAbsoluteTimeGetCurrent()
      let text = try await LocalSpeechService.shared.transcribe(audioURL: audioURL, language: "de")
      let decode = CFAbsoluteTimeGetCurrent() - decodeStart

      print(
        "BENCH-OFFLINE \(label) audioS=\(String(format: "%.2f", audioSeconds)) "
          + "decodeS=\(String(format: "%.2f", decode)) "
          + "rtf=\(String(format: "%.3f", decode / audioSeconds)) "
          + "chars=\(text.count)")
      #expect(!text.isEmpty)
    }

    // Unload and reload, then decode a clip whose warm cost is already known from the loop above:
    // the difference is the per-load penalty on the first decode. It is real (~+3.7 s on an M1
    // Pro) and it returns after every unload, so it is not a once-per-process cost. A throwaway
    // warm-up inference was tried against it and did not absorb it (2026-09-02) — see
    // `plans/active/streaming-dictate.md`.
    // The medium clip, deliberately: the short one turned out to be intrinsically expensive
    // (its decode costs ~5 s warm as well), so measuring a cold start with it cannot separate
    // "first decode after a load" from "this clip is slow".
    let probe = workDir.appendingPathComponent("probe.wav")
    try Self.makeSpeech(sentenceCount: 5, at: probe)
    let probeSeconds = try Self.duration(of: probe)

    // Three arms, each from a freshly reloaded model, isolating what does and does not absorb the
    // per-load penalty on the first decode:
    //   none      — the penalty itself, measured on a clip whose warm cost is known
    //   recording — a real 16 kHz speech clip first, the format the recorder produces
    //   synth     — an AVSpeechSynthesizer clip first (22 kHz float), the one the reverted
    //               `warmUpInference` used; its transcript length is printed, because a warm-up
    //               that decodes to nothing tests nothing
    let warmClip = workDir.appendingPathComponent("warm-recording.wav")
    try Self.makeSpeech(sentenceCount: 1, at: warmClip)
    let synthClip = workDir.appendingPathComponent("warm-synth.wav")
    let haveSynthClip = await Self.writeSynthesizedClip(at: synthClip)

    for arm in ["none", "recording", "synth"] {
      if arm == "synth" && !haveSynthClip { continue }

      await LocalSpeechService.shared.unloadModel()
      let reloadStart = CFAbsoluteTimeGetCurrent()
      try await LocalSpeechService.shared.initializeModel(type)
      let reload = CFAbsoluteTimeGetCurrent() - reloadStart

      var warmSeconds = 0.0
      var warmChars = 0
      if arm != "none" {
        let clip = arm == "recording" ? warmClip : synthClip
        let warmStart = CFAbsoluteTimeGetCurrent()
        let warmText = (try? await LocalSpeechService.shared.transcribe(audioURL: clip, language: "de")) ?? ""
        warmSeconds = CFAbsoluteTimeGetCurrent() - warmStart
        warmChars = warmText.count
      }

      let probeStart = CFAbsoluteTimeGetCurrent()
      _ = try await LocalSpeechService.shared.transcribe(audioURL: probe, language: "de")
      let probeDecode = CFAbsoluteTimeGetCurrent() - probeStart

      print(
        "BENCH-OFFLINE reload warm=\(arm) "
          + "loadS=\(String(format: "%.2f", reload)) "
          + "warmS=\(String(format: "%.2f", warmSeconds)) warmChars=\(warmChars) "
          + "probeAudioS=\(String(format: "%.2f", probeSeconds)) "
          + "probeDecodeS=\(String(format: "%.2f", probeDecode))")
    }
  }

  /// Does WhisperKit's VAD chunking make a long dictation land sooner?
  ///
  /// The app decodes with `chunkingStrategy: nil` today, which walks the audio one 30 s window
  /// after another. `.vad` instead cuts at voice-activity boundaries and hands the pieces to
  /// `concurrentWorkerCount` workers (16 on macOS), so windows that are currently serialised
  /// overlap. It changes nothing for a dictation under 30 s — one window is not chunkable — so
  /// this measures only the lengths where it could matter.
  ///
  /// Two things have to hold before it can ship, and this test prints both:
  ///   - **speed**: `decodeS` for `.vad` clearly below sequential on the same clip, outside the
  ///     ~20 % run-to-run spread the suite above already documented (hence two repeats per arm)
  ///   - **quality**: chunks decode independently, so cross-chunk conditioning is lost and seams
  ///     can drop or duplicate words. The transcripts are printed in full; a shorter `.vad`
  ///     transcript is the falsifier, not a rounding difference.
  @Test(
    "VAD chunking vs sequential windows on long dictations",
    .enabled(if: isEnabled, "Set WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER=1 to run (loads ~1.6 GB)")
  )
  func chunkingStrategyComparison() async throws {
    let type = Self.modelType
    #expect(ModelManager.shared.isModelAvailable(type), "Download \(type.displayName) first")

    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("offline-whisper-chunking-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    try await LocalSpeechService.shared.initializeModel(type)

    // One decode before the arms so the ~4 s first-decode-after-load penalty is spent outside
    // the comparison rather than landing on whichever arm happens to run first.
    let warm = workDir.appendingPathComponent("warm.wav")
    try Self.makeSpeech(sentenceCount: 2, at: warm)
    _ = try await LocalSpeechService.shared.transcribe(audioURL: warm, language: "de")

    // 14 sentences ≈ 60 s (two windows), 26 ≈ 110 s (four): chunking cannot help below one
    // window, and the gain should grow with the number of windows if it is real parallelism.
    for (label, sentenceCount) in [("long", 14), ("longer", 26)] {
      let audioURL = workDir.appendingPathComponent("\(label).wav")
      try Self.makeSpeech(sentenceCount: sentenceCount, at: audioURL)
      let audioSeconds = try Self.duration(of: audioURL)

      for repeatIndex in 0..<2 {
        for strategy: ChunkingStrategy? in [nil, .vad] {
          let start = CFAbsoluteTimeGetCurrent()
          let text = try await LocalSpeechService.shared.transcribe(
            audioURL: audioURL, language: "de", chunkingStrategy: strategy)
          let decode = CFAbsoluteTimeGetCurrent() - start

          print(
            "BENCH-CHUNKING \(label) run=\(repeatIndex) "
              + "strategy=\(strategy?.rawValue ?? "sequential") "
              + "audioS=\(String(format: "%.2f", audioSeconds)) "
              + "decodeS=\(String(format: "%.2f", decode)) "
              + "rtf=\(String(format: "%.3f", decode / audioSeconds)) "
              + "chars=\(text.count)")
          if repeatIndex == 0 {
            print("BENCH-CHUNKING-TEXT \(label) \(strategy?.rawValue ?? "sequential"): \(text)")
          }
          #expect(!text.isEmpty)
        }
      }
    }
  }

  /// Slice 4's actual claim, end to end: does transcribing chunks *while the user speaks* make the
  /// wait after Stop the tail chunk's decode instead of the whole dictation's?
  ///
  /// This drives the real `DictateStreamingSession` through the real `SpeechService` and
  /// `LocalSpeechService`. The only thing it stands in for is the microphone and
  /// `ChunkedDictateRecorder`'s silence detection: chunks are pre-cut and handed to the session
  /// **in real time** — each one is delivered only after its own audio duration has elapsed, which
  /// is when the recorder would have rotated it out. Feeding them all at once would let every
  /// decode run before "Stop" and measure nothing.
  ///
  /// So it answers "does the pipeline turn a rotated chunk into a finished transcript before Stop",
  /// not "does the recorder rotate at the right moments" — that second half needs a real dictation
  /// with real pauses.
  @Test(
    "Streaming leaves only the tail chunk after Stop",
    .enabled(if: isEnabled, "Set WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER=1 to run (loads ~1.6 GB)")
  )
  func streamingVersusOneShot() async throws {
    // Unbuffered: on the failure path the host exits before a buffered stdout is flushed, which
    // silently swallows exactly the diagnostics you need.
    setvbuf(stdout, nil, _IONBF, 0)
    func step(_ label: String) { print("BENCH-STREAMING-STEP \(label)") }
    let type = Self.modelType
    #expect(ModelManager.shared.isModelAvailable(type), "Download \(type.displayName) first")

    let defaults = UserDefaults.standard
    let previousSelection = defaults.string(forKey: UserDefaultsKeys.selectedTranscriptionModel)
    defaults.set(
      TranscriptionModel.forOfflineModel(type).rawValue,
      forKey: UserDefaultsKeys.selectedTranscriptionModel)
    defer {
      if let previousSelection {
        defaults.set(previousSelection, forKey: UserDefaultsKeys.selectedTranscriptionModel)
      } else {
        defaults.removeObject(forKey: UserDefaultsKeys.selectedTranscriptionModel)
      }
    }

    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("offline-whisper-streaming-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    // Five chunks of three sentences each ≈ 15 s per chunk, ≈ 73 s total — a long dictation with
    // four pauses, the shape where streaming is supposed to pay.
    var chunkURLs: [URL] = []
    var chunkSeconds: [Double] = []
    for index in 0..<5 {
      let url = workDir.appendingPathComponent("chunk-\(index).wav")
      try Self.makeSpeech(sentenceCount: 3, at: url, startingAt: index * 3)
      chunkURLs.append(url)
      chunkSeconds.append(try Self.duration(of: url))
      step("made chunk \(index)")
    }
    let totalSeconds = chunkSeconds.reduce(0, +)
    // Arm B's clip is synthesised in one go rather than stitched from the chunk files: writing a
    // WAV with AVAudioFile fails inside this sandboxed test host, and it is not needed. The
    // sentence sequence is identical by construction — chunk i covers sentences 3i…3i+2 and the
    // full clip covers 0…14, both indexing the same array modulo its length — so both arms decode
    // the same words in the same order. Only the prosody at the five joins differs, which changes
    // the audio but not the token count that dominates decode cost.
    let merged = workDir.appendingPathComponent("merged.wav")
    try Self.makeSpeech(sentenceCount: 15, at: merged)
    let mergedSeconds = try Self.duration(of: merged)
    step("full clip made")

    // Weights warm for both arms: the load is `ConnectionPrewarmer`'s job and would otherwise land
    // on whichever arm runs first.
    try await LocalSpeechService.shared.initializeModel(type)
    step("model ready")
    _ = try await LocalSpeechService.shared.transcribe(audioURL: chunkURLs[0], language: "de")
    step("warm decode done")

    // ---- Arm A: streaming, chunks arriving in real time ----
    let speechService = SpeechService()
    let selected = TranscriptionModel.loadSelected()
    print(
      "BENCH-STREAMING-GATE selected=\(selected.rawValue) isOffline=\(selected.isOffline) "
        + "offlineType=\(selected.offlineModelType?.rawValue ?? "nil") "
        + "downloaded=\(selected.isOfflineModelAvailable()) "
        + "chunkedRecorder=\(AppConstants.useChunkedDictateRecorder) "
        + "isEligible=\(DictateStreamingSession.isEligible(model: selected, hasCredential: selected.hasRequiredCredential, offlineModelDownloaded: selected.isOfflineModelAvailable()))")
    let session = try #require(
      DictateStreamingSession.makeIfEligible(speechService: speechService),
      "the gate should admit a downloaded offline model — this is slice 4")

    for index in 0..<(chunkURLs.count - 1) {
      // The recorder would hand this chunk over only once it had been spoken.
      try await Task.sleep(for: .seconds(chunkSeconds[index]))
      session.addChunk(url: chunkURLs[index], index: index, isSilent: false)
    }
    try await Task.sleep(for: .seconds(chunkSeconds[chunkURLs.count - 1]))

    // Stop.
    let stopTime = CFAbsoluteTimeGetCurrent()
    session.addFinalChunk(url: chunkURLs[chunkURLs.count - 1], index: chunkURLs.count - 1, isSilent: false)
    let streamedText = try await session.finalTranscript()
    let streamedAfterStop = CFAbsoluteTimeGetCurrent() - stopTime

    // ---- Arm B: one-shot on the merged WAV, the pre-slice-4 behaviour ----
    let oneShotStart = CFAbsoluteTimeGetCurrent()
    let oneShotText = try await speechService.transcribe(audioURL: merged, cancellable: false)
    let oneShotAfterStop = CFAbsoluteTimeGetCurrent() - oneShotStart

    print(
      "BENCH-STREAMING chunkedAudioS=\(String(format: "%.1f", totalSeconds)) "
        + "oneShotAudioS=\(String(format: "%.1f", mergedSeconds)) "
        + "chunks=\(chunkURLs.count) tailS=\(String(format: "%.1f", chunkSeconds.last ?? 0)) "
        + "streamedAfterStopS=\(String(format: "%.2f", streamedAfterStop)) "
        + "oneShotAfterStopS=\(String(format: "%.2f", oneShotAfterStop)) "
        + "speedup=\(String(format: "%.1f", oneShotAfterStop / max(streamedAfterStop, 0.001)))x")
    print("BENCH-STREAMING-TEXT streamed: \(streamedText ?? "<nil — fell back to single-shot>")")
    print("BENCH-STREAMING-TEXT oneshot : \(oneShotText)")

    // The falsifier from plans/implementer-queue.md row 3, as an assertion rather than a log line:
    // a nil transcript means the session gave up and the merged-WAV fallback would have run, and a
    // wait that is not clearly shorter than one-shot means streaming bought nothing.
    let streamed = try #require(streamedText, "streaming fell back to single-shot")
    #expect(!streamed.isEmpty)
    // Strictly faster, not a fixed multiple. Measured on an M1 Pro across four runs: 3.2x, 3.4x,
    // 1.6x, and once a fallback (see below) — the spread is wide because the decode competes with
    // whatever else the Mac is doing, and a hard 2x gate turns this benchmark into a coin flip.
    // The claim being defended is "the wait after Stop is the tail, not the whole dictation"; the
    // printed ratio is the number to read, this is the floor under it.
    #expect(
      streamedAfterStop < oneShotAfterStop,
      "stop-to-transcript \(streamedAfterStop)s should beat the one-shot \(oneShotAfterStop)s")
  }

  /// Same-audio A/B for Whisper's conditioning prompt: does a domain glossary actually lift
  /// specialist terms, and does a style instruction do anything at all?
  ///
  /// OpenAI's own Whisper docs say the prompt is a spelling dictionary of up to 224 tokens, and
  /// that Whisper "doesn't follow instructions like a general-purpose text model"
  /// (https://developers.openai.com/api/docs/guides/speech-to-text — Improving reliability).
  /// The sales pitch that a sentence like "Befundbericht einer Praxis. Satzzeichen ausschreiben"
  /// would steer punctuation is therefore the interesting falsifier, not a second vocabulary list.
  ///
  /// Two clips, three arms, same WAV each time:
  ///   osteopathy — a finding packed with terms Small is likely to miss
  ///   everyday   — a short sentence with none of those terms (echo / hallucination check)
  ///   none / terms / style
  ///
  /// TTS (`say -v Anna`) is clean studio speech, so absolute accuracy is optimistic. A miss here
  /// is a strong signal; a hit still wants a live dictation to confirm.
  @Test(
    "Glossary prompt A/B on osteopathy terms",
    .enabled(if: isEnabled, "Set WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER=1 to run (loads the model)")
  )
  func glossaryPromptAB() async throws {
    let type = Self.modelType
    #expect(ModelManager.shared.isModelAvailable(type), "Download \(type.displayName) first")

    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("offline-whisper-glossary-ab-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    try await LocalSpeechService.shared.initializeModel(type)

    let osteopathy = """
      Die Patientin kommt mit akuter Lumbalgie nach einer Hebebewegung. \
      Palpation zeigt eine deutliche Faszieneinschränkung im Bereich des Sacrum und der Halswirbelsäule. \
      Verdacht auf Blockade des Iliosakralgelenks. \
      Behandlung osteopathisch mit Fokus auf myofasziale Techniken und craniosacrale Impulse. \
      Triggerpunkte paravertebral links.
      """
    let everyday = "Heute ist schönes Wetter und ich gehe später einkaufen."
    let termsPrompt =
      "Osteopathie, Halswirbelsäule, Lumbalgie, Sacrum, Faszieneinschränkung, "
      + "Iliosakralgelenk, Triggerpunkt, Myofaszial, Craniosacral, Blockade"
    let stylePrompt = "Befundbericht einer Praxis. Satzzeichen wie Punkt und Komma ausschreiben."

    struct Term {
      let label: String
      let needles: [String]
    }
    let scored: [Term] = [
      Term(label: "Lumbalgie", needles: ["lumbalgie"]),
      Term(label: "Faszieneinschränkung", needles: ["faszieneinschränkung", "faszieneinschraenkung"]),
      Term(label: "Sacrum", needles: ["sacrum", "sakrum"]),
      Term(label: "Halswirbelsäule", needles: ["halswirbelsäule", "halswirbelsaeule"]),
      Term(label: "Blockade", needles: ["blockade"]),
      Term(label: "Iliosakralgelenk", needles: ["iliosakralgelenk", "ilio-sakralgelenk"]),
      Term(label: "osteopathisch", needles: ["osteopath"]),
      Term(label: "myofaszial", needles: ["myofaszial", "myofascial"]),
      Term(label: "craniosacral", needles: ["craniosacral", "kraniosakral", "kraniosacral"]),
      Term(label: "Triggerpunkt", needles: ["triggerpunkt", "trigger-punkt"]),
    ]
    let decoys = ["lumbalgie", "sacrum", "sakrum", "faszieneinschränkung", "iliosakral"]

    func folded(_ text: String) -> String {
      text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }
    func hits(in text: String) -> [String] {
      let hay = folded(text)
      return scored.filter { term in
        term.needles.contains { hay.contains(folded($0)) }
      }.map(\.label)
    }

    let osteoURL = workDir.appendingPathComponent("osteopathy.wav")
    let everydayURL = workDir.appendingPathComponent("everyday.wav")
    try Self.makeSpeech(text: osteopathy, at: osteoURL)
    try Self.makeSpeech(text: everyday, at: everydayURL)

    // Spend the first-decode-after-load penalty outside the comparison.
    _ = try await LocalSpeechService.shared.transcribe(audioURL: everydayURL, language: "de")

    let arms: [(String, String?)] = [
      ("none", nil),
      ("terms", termsPrompt),
      ("style", stylePrompt),
    ]

    print("GLOSSARY-AB model=\(type.rawValue)")
    print("GLOSSARY-AB source: \(osteopathy)")

    var osteoHits: [String: [String]] = [:]
    var osteoTexts: [String: String] = [:]
    for (name, prompt) in arms {
      let text = try await LocalSpeechService.shared.transcribe(
        audioURL: osteoURL, language: "de", prompt: prompt)
      let found = hits(in: text)
      osteoHits[name] = found
      osteoTexts[name] = text
      print("GLOSSARY-AB osteopathy arm=\(name) hits=\(found.count)/\(scored.count) text=\(text)")
    }

    print("GLOSSARY-AB scoreboard (osteopathy):")
    for term in scored {
      let row = arms.map { name, _ in
        let ok = osteoHits[name]?.contains(term.label) == true
        return ok ? "yes" : "no "
      }.joined(separator: "  ")
      print("GLOSSARY-AB   \(term.label.padding(toLength: 22, withPad: " ", startingAt: 0)) none/terms/style  \(row)")
    }

    for (name, prompt) in arms {
      let text = try await LocalSpeechService.shared.transcribe(
        audioURL: everydayURL, language: "de", prompt: prompt)
      let hay = folded(text)
      let echoed = decoys.filter { hay.contains(folded($0)) }
      print(
        "GLOSSARY-AB everyday arm=\(name) echo=\(echoed.isEmpty ? "none" : echoed.joined(separator: ",")) text=\(text)")
    }

    // The test records, it does not gate a product claim: a 0-for-10 on `terms` is a finding,
    // not a build break. Keep a floor so a totally empty decode still fails loudly.
    #expect(!(osteoTexts["none"] ?? "").isEmpty)
    #expect(!(osteoTexts["terms"] ?? "").isEmpty)
  }

  /// The clip the reverted product warm-up produced: a system voice at its native rate, not the
  /// recorder's 16 kHz. Written here rather than in the app so the experiment can compare it
  /// against a real recording without shipping either.
  private static func writeSynthesizedClip(at url: URL) async -> Bool {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(
      string: "Dies ist eine Aufwärmung des Modells, der Text wird sofort verworfen.")
    utterance.voice = AVSpeechSynthesisVoice(language: "de-DE")
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      var file: AVAudioFile?
      var finished = false
      synthesizer.write(utterance) { buffer in
        guard !finished, let pcm = buffer as? AVAudioPCMBuffer else { return }
        guard pcm.frameLength > 0 else {
          finished = true
          continuation.resume(returning: file != nil)
          return
        }
        do {
          if file == nil {
            file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
          }
          try file?.write(from: pcm)
        } catch {
          finished = true
          continuation.resume(returning: false)
        }
      }
    }
  }
}
