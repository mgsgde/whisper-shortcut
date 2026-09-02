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
  private static func makeSpeech(sentenceCount: Int, at url: URL) throws {
    let text = (0..<sentenceCount).map { sentences[$0 % sentences.count] }.joined(separator: " ")
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
        userInfo: [NSLocalizedDescriptionKey: "`say` failed for \(sentenceCount) sentences"])
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
