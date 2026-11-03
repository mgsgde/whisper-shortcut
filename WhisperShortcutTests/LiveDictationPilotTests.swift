import AVFoundation
import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// End-to-end regression pilot for Dictate Live as a doctor uses it, without a human at the
/// microphone: German speech from `say -v Anna` → the app's offline path (Parakeet Ultra, Glossary
/// vocabulary boosting, the vocabulary guard) → `LiveDictation.finishPiece`.
///
/// Opt-in via `WHISPERSHORTCUT_BENCH_PARAKEET=1` (test-plan environment variable, see
/// `OfflineWhisperBenchmarkTests` for why the command line does not work). Prints one `PILOT ` line
/// per case and mode, tab-separated: id, mode, raw, boosted, final, expected, PASS/FAIL.
/// Expectations apply to `.spokenOnly`; `.automatic` is reported only (`-`).
@Suite("Live dictation pilot", .serialized)
struct LiveDictationPilotTests {

  private static var liveEnabled: Bool {
    ProcessInfo.processInfo.environment["WHISPERSHORTCUT_BENCH_PARAKEET"] == "1"
  }

  private struct PilotCase {
    let id: String
    let speech: String
    let expected: String
    var extraTerms: [String] = []
  }

  private static let baseGlossary = ["GdB", "VersMedV", "ADL", "Merkzeichen"]

  private static let cases: [PilotCase] = [
    PilotCase(id: "fill1", speech: "Hmm, Gangbild unauffällig Punkt", expected: "Gangbild unauffällig."),
    PilotCase(id: "fill2", speech: "Basistherapie ähm Methotrexat Punkt", expected: "Basistherapie Methotrexat."),
    PilotCase(id: "slash1", speech: "Arbeitsmarkt Schrägstrich im A D L", expected: "Arbeitsmarkt/im ADL"),
    PilotCase(id: "slash2", speech: "Arbeitsmarkt Schräg Strich Bewegung", expected: "Arbeitsmarkt/Bewegung"),
    PilotCase(id: "ell1", speech: "Gesamt G d B drei Pünktchen und dann weiter", expected: "Gesamt GdB… und dann weiter"),
    PilotCase(id: "keep1", speech: "Um zehn Uhr kam die Patientin", expected: "Um 10 Uhr kam die Patientin"),
    PilotCase(id: "keep2", speech: "Sie hat drei Punkte erreicht", expected: "Sie hat drei Punkte erreicht"),
    PilotCase(id: "keep3", speech: "Die Schrägstriche fehlen", expected: "Die Schrägstriche fehlen"),
    PilotCase(id: "comma1", speech: "Gangbild Komma geht weiter Punkt", expected: "Gangbild, geht weiter."),
    PilotCase(id: "ah1", speech: "Ah stimmt die Dosis", expected: "A stimmt die Dosis"),
    PilotCase(
      id: "A", speech: "Gesamt G d B fünfzig Komma Merkzeichen G nicht begründet Punkt",
      expected: "Gesamt GdB 50, Merkzeichen G nicht begründet."),
    PilotCase(
      id: "B", speech: "Gangbild Komma Gehstrecke laut Befund unter fünfhundert Meter Punkt",
      expected: "Gangbild, Gehstrecke laut Befund unter 500 Meter."),
    PilotCase(
      id: "C",
      speech: "Leistungsfähigkeit auf dem allgemeinen Arbeitsmarkt Schrägstrich im A D L eingeschränkt Punkt",
      expected: "Leistungsfähigkeit auf dem allgemeinen Arbeitsmarkt/im ADL eingeschränkt."),
    PilotCase(
      id: "E",
      speech: "Widerspruch Doppelpunkt Neue Befunde liegen nicht vor Punkt Entscheidung nach Aktenlage Punkt",
      expected: "Widerspruch: Neue Befunde liegen nicht vor. Entscheidung nach Aktenlage."),
    PilotCase(
      id: "F",
      speech: "Wirbelsäule Komma Hüfte beidseits Komma Knie rechts drei Pünktchen weitere Befunde angefordert Punkt",
      expected: "Wirbelsäule, Hüfte beidseits, Knie rechts… weitere Befunde angefordert."),
    PilotCase(
      id: "K", speech: "Gangbild Komma geht weiter Punkt", expected: "Gangbild, geht weiter.",
      extraTerms: ["Kizomba"]),
  ]

  @Test(
    "Live dictation cases, TTS to final text",
    .enabled(if: liveEnabled, "Set WHISPERSHORTCUT_BENCH_PARAKEET=1 in the test plan to run"))
  func pilot() async throws {
    setvbuf(stdout, nil, _IONBF, 0)
    try await ModelManager.shared.ensureReady(.parakeetUltra)
    try await LocalSpeechService.shared.initializeModel(.parakeetUltra)

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("live-pilot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func tab(_ s: String) -> String {
      s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "⏎")
    }

    var passed = 0
    for pilotCase in Self.cases {
      let url = dir.appendingPathComponent("\(pilotCase.id).wav")
      try Self.say(pilotCase.speech, to: url)
      let glossary = Self.baseGlossary + pilotCase.extraTerms
      let raw = try await LocalSpeechService.shared.transcribe(audioURL: url, language: "de")
      let boosted = try await LocalSpeechService.shared.transcribe(
        audioURL: url, language: "de", vocabulary: glossary)

      for mode in [PunctuationMode.spokenOnly, .automatic] {
        let final = LiveDictation.finishPiece(boosted, mode: mode)
        let isSpokenOnly = mode == .spokenOnly
        let verdict: String
        let expectedColumn: String
        if isSpokenOnly {
          let ok = final == pilotCase.expected
          if ok { passed += 1 }
          verdict = ok ? "PASS" : "FAIL"
          expectedColumn = pilotCase.expected
          #expect(final == pilotCase.expected, "\(pilotCase.id): raw=\(raw) boosted=\(boosted)")
        } else {
          verdict = "-"
          expectedColumn = "-"
        }
        print(
          "PILOT "
            + [pilotCase.id, mode.rawValue, tab(raw), tab(boosted), tab(final), tab(expectedColumn), verdict]
            .joined(separator: "\t"))
      }
    }
    print("PILOT SUMMARY spokenOnly pass=\(passed)/\(Self.cases.count)")
  }

  /// Measurement only: does a spoken "Komma" leave its own audio time behind the "," token that
  /// Parakeet writes, compared with a "," it guesses where nothing was said? Prints one `COMMA `
  /// line per "," token; asserts nothing.
  @Test(
    "Comma token timing, spoken vs guessed",
    .enabled(if: liveEnabled, "Set WHISPERSHORTCUT_BENCH_PARAKEET=1 in the test plan to run"))
  func commaTiming() async throws {
    setvbuf(stdout, nil, _IONBF, 0)
    try await ModelManager.shared.ensureReady(.parakeetUltra)
    let backend = try await ParakeetBackend.load()

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("comma-timing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sentences: [(kind: String, text: String)] = [
      ("spoken", "Wirbelsäule Komma Hüfte beidseits Komma Knie rechts"),
      ("spoken", "Gangbild Komma geht weiter"),
      ("spoken", "Gesamt GdB fünfzig Komma Merkzeichen G"),
      ("guessed", "Wenn das so ist dann gehen wir weiter"),
      ("guessed", "Hüfte rechts Knie links Schulter beidseits"),
      ("guessed", "Ich glaube er kommt morgen"),
    ]
    func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    for (index, sentence) in sentences.enumerated() {
      let url = dir.appendingPathComponent("c\(index).wav")
      try Self.say(sentence.text, to: url)
      let result = try await backend.rawTokenTimings(audioURL: url, language: "de")
      let hasKomma = result.text.lowercased().contains("komma")
      print("COMMA TEXT kind=\(sentence.kind) sentence=\(index + 1) komma=\(hasKomma) raw=\(result.text)")
      for (i, token) in result.tokens.enumerated() where token.token.trimmingCharacters(in: .whitespaces) == "," {
        let before = i > 0 ? ms(token.start - result.tokens[i - 1].end) : 0
        let after = i + 1 < result.tokens.count ? ms(result.tokens[i + 1].start - token.end) : 0
        print(
          "COMMA kind=\(sentence.kind) sentence=\(index + 1) tokenMs=\(ms(token.end - token.start)) "
            + "gapBeforeMs=\(before) gapAfterMs=\(after) rawContainsKomma=\(hasKomma)")
      }
    }
  }

  private static func say(_ text: String, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", "Anna", "-o", url.path, "--data-format=LEI16@16000", text]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "LiveDictationPilotTests", code: Int(process.terminationStatus))
    }
  }
}
