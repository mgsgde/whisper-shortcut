import AVFoundation
import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Parakeet Ultra as an offline engine (`plans/active/parakeet-offline.md`, slice 1).
@Suite("Parakeet offline engine")
struct ParakeetOfflineTests {

  /// The Offline Mode guarantee, checked without a network: FluidAudio's loader re-downloads a
  /// missing model on its own unless its network switch is shut, and `OfflineModeURLProtocol` does
  /// not cover FluidAudio's URLSession. Loading from an empty folder must therefore fail as
  /// "missing", fast — not attempt a download.
  @Test("Loading never reaches for the network")
  func loadIsOfflineOnly() async throws {
    let empty = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("parakeet-empty-\(UUID().uuidString)/parakeet-ultra")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty.deletingLastPathComponent()) }

    let start = Date()
    var failure: Error?
    do {
      _ = try await ParakeetBackend.loadModelsOffline(from: empty)
    } catch {
      failure = error
    }
    let message = "\(failure.map { String(describing: $0) } ?? "no error")"
    #expect(failure != nil, "an empty folder must not load")
    #expect(
      message.localizedCaseInsensitiveContains("offline")
        || message.localizedCaseInsensitiveContains("missing"),
      "expected FluidAudio's offline refusal, got: \(message)")
    #expect(Date().timeIntervalSince(start) < 5, "a refusal is immediate; a download attempt is not")
  }

  // MARK: - Live (opt-in)

  private static var liveEnabled: Bool {
    ProcessInfo.processInfo.environment["WHISPERSHORTCUT_BENCH_PARAKEET"] == "1"
  }

  /// Slice 1's acceptance numbers through the app's own path — `ModelManager.ensureReady` (download
  /// into the container, then load) and `LocalSpeechService.transcribe` — on German practice
  /// dictation spoken by `say`. Downloads ~700 MB on first run, hence opt-in; enable it the way
  /// `OfflineWhisperBenchmarkTests` documents (test-plan environment variable, then restore).
  @Test(
    "Post-Stop wait on the app path",
    .enabled(if: liveEnabled, "Set WHISPERSHORTCUT_BENCH_PARAKEET=1 in the test plan to run"))
  func postStopWait() async throws {
    setvbuf(stdout, nil, _IONBF, 0)
    func f(_ v: Double) -> String { String(format: "%.2f", v) }

    let wasDownloaded = ModelManager.shared.isModelAvailable(.parakeetUltra)
    let readyStart = Date()
    try await ModelManager.shared.ensureReady(.parakeetUltra)
    print(
      "BENCH-PARAKEET ready wasDownloaded=\(wasDownloaded) "
        + "readyS=\(f(Date().timeIntervalSince(readyStart)))")
    #expect(ModelManager.shared.isModelAvailable(.parakeetUltra))

    // Cold load from the compile cache, the cost after an idle or memory-pressure unload.
    await LocalSpeechService.shared.unloadModel()
    let loadStart = Date()
    try await LocalSpeechService.shared.initializeModel(.parakeetUltra)
    print("BENCH-PARAKEET reloadS=\(f(Date().timeIntervalSince(loadStart)))")

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("parakeet-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sentence = "Der Patient klagt seit drei Tagen über ziehende Beschwerden im rechten Oberbauch."
    let minute = Array(repeating: [
      sentence,
      "Die körperliche Untersuchung zeigt einen weichen Bauch ohne Abwehrspannung.",
      "Im Labor sind die Entzündungswerte leicht erhöht, das Blutbild ist unauffällig.",
      "Die Sonographie des Abdomens ergibt keinen Hinweis auf Gallensteine.",
    ].joined(separator: " "), count: 4).joined(separator: " ")

    // First decode after a load is timed on its own, like the Whisper benchmark does.
    for (label, text, budget) in [
      ("first", sentence, 2.0), ("sentence", sentence, 0.3), ("minute", minute, 1.0),
    ] {
      let url = dir.appendingPathComponent("\(label).wav")
      try Self.say(text, to: url)
      let file = try AVAudioFile(forReading: url)
      let audioSeconds = Double(file.length) / file.fileFormat.sampleRate
      let start = Date()
      let transcript = try await LocalSpeechService.shared.transcribe(audioURL: url, language: "de")
      let decode = Date().timeIntervalSince(start)
      print(
        "BENCH-PARAKEET \(label) audioS=\(f(audioSeconds)) decodeS=\(f(decode)) chars=\(transcript.count)")
      #expect(!transcript.isEmpty)
      #expect(decode < budget, "\(label): \(f(decode)) s against a \(budget) s budget")
    }
  }

  private static func say(_ text: String, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", "Anna", "-o", url.path, "--data-format=LEI16@16000", text]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "ParakeetOfflineTests", code: Int(process.terminationStatus))
    }
  }
}
