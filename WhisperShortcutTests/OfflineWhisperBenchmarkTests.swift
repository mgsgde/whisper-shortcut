import Testing
import Foundation
import AVFoundation
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
/// The flag has to be passed **twice**, because a plain export does not reach the test host and the
/// suite then silently reports as passed in 0.001 s:
///
///     WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER=1 TEST_RUNNER_WHISPERSHORTCUT_BENCH_OFFLINE_WHISPER=1 \
///       xcodebuild test -scheme WhisperShortcut-AppStore -testPlan WhisperShortcut-AppStore \
///       -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests \
///       -only-testing:WhisperShortcutTests/OfflineWhisperBenchmarkTests
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

    await LocalSpeechService.shared.unloadModel()
    let reloadStart = CFAbsoluteTimeGetCurrent()
    try await LocalSpeechService.shared.initializeModel(type)
    let reload = CFAbsoluteTimeGetCurrent() - reloadStart

    let probeStart = CFAbsoluteTimeGetCurrent()
    _ = try await LocalSpeechService.shared.transcribe(audioURL: probe, language: "de")
    let probeDecode = CFAbsoluteTimeGetCurrent() - probeStart

    print(
      "BENCH-OFFLINE reload loadS=\(String(format: "%.2f", reload)) "
        + "audioS=\(String(format: "%.2f", probeSeconds)) "
        + "firstDecodeS=\(String(format: "%.2f", probeDecode))")
  }
}
