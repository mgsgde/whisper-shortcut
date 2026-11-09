import AVFoundation
import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Timing measurement for Dictate Live's "Only when spoken" punctuation. The pass/fail dictation
/// cases that used to live here moved to `DictationBenchmarkTests` and `benchmarks/dictation/`
/// (run with `scripts/dictation-benchmark.sh`); this file keeps `punctuationTiming`, which asserts
/// nothing and only prints how spoken and guessed marks differ in Parakeet's token timing.
///
/// Opt-in via `WHISPERSHORTCUT_BENCH_PARAKEET=1` (test-plan environment variable, see
/// `OfflineWhisperBenchmarkTests` for why the command line does not work).
@Suite("Live dictation pilot", .serialized)
struct LiveDictationPilotTests {

  private static var liveEnabled: Bool {
    ProcessInfo.processInfo.environment["WHISPERSHORTCUT_BENCH_PARAKEET"] == "1"
  }

  /// Measurement only: in "Only when spoken" mode a spoken "Komma"/"Punkt" (which Parakeet often
  /// writes as "," / "." itself) must be told apart from punctuation Parakeet guessed. Prints one
  /// `PUNCT ` line per punctuation token (gaps to neighbouring tokens, distance to audio end),
  /// `PUNCT-AUDIO ` per sentence and `PUNCT-SUMMARY ` per kind and mark. Asserts nothing.
  @Test(
    "Punctuation token timing, spoken vs guessed",
    .enabled(if: liveEnabled, "Set WHISPERSHORTCUT_BENCH_PARAKEET=1 in the test plan to run"))
  func punctuationTiming() async throws {
    setvbuf(stdout, nil, _IONBF, 0)
    try await ModelManager.shared.ensureReady(.parakeetUltra)
    let backend = try await ParakeetBackend.load()

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("punct-timing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let voices: [(label: String, name: String, rate: Int?)] = [
      ("Anna", "Anna", nil),
      ("Anna-r150", "Anna", 150),
      ("Anna-r220", "Anna", 220),
      ("Eddy", "Eddy (German (Germany))", nil),
      ("Flo", "Flo (German (Germany))", nil),
      ("Reed", "Reed (German (Germany))", nil),
      ("Sandy", "Sandy (German (Germany))", nil),
      ("Shelley", "Shelley (German (Germany))", nil),
    ]
    let sentences: [(kind: String, text: String)] = [
      ("spokenComma", "Wirbelsäule Komma Hüfte beidseits Komma Knie rechts"),
      ("spokenComma", "Gangbild Komma geht weiter"),
      ("spokenComma", "Gesamt GdB fünfzig Komma Merkzeichen G"),
      ("spokenComma", "Hüfte rechts Komma Knie links"),
      ("spokenComma", "Befund unauffällig Komma keine Einschränkung"),
      ("spokenPeriod", "Die Dosis stimmt Punkt"),
      ("spokenPeriod", "Gangbild unauffällig Punkt"),
      ("spokenPeriod", "Sie hat drei Punkte erreicht Punkt"),
      ("spokenPeriod", "Entscheidung nach Aktenlage Punkt"),
      ("spokenPeriod", "Weitere Befunde angefordert Punkt"),
      ("guessed", "Wenn das so ist dann gehen wir weiter"),
      ("guessed", "Hüfte rechts Knie links Schulter beidseits"),
      ("guessed", "Ich glaube er kommt morgen"),
      ("guessed", "Die Dosis stimmt"),
      ("guessed", "Gangbild unauffällig"),
      ("guessed", "Um zehn Uhr kam die Patientin"),
      ("guessed", "Entscheidung nach Aktenlage"),
      ("guessed", "Wirbelsäule Hüfte beidseits Knie rechts"),
      ("guessed", "Weil sie Schmerzen hat kommt sie später"),
      ("guessed", "Basistherapie Methotrexat"),
    ]
    func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
    let marks: Set<String> = [",", ".", "?", "!"]

    struct Sample { let kind: String, mark: String, pos: String, token: Int, after: Int, tail: Int? }
    var samples: [Sample] = []

    for voice in voices {
      for (index, sentence) in sentences.enumerated() {
        let url = dir.appendingPathComponent("\(voice.label)-\(index).wav")
        try Self.say(sentence.text, voice: voice.name, rate: voice.rate, to: url)
        let file = try AVAudioFile(forReading: url)
        let audioEnd = Double(file.length) / file.processingFormat.sampleRate
        let result = try await backend.rawTokenTimings(audioURL: url, language: "de")
        let tokens = result.tokens
        let rawHasWord = ["komma", "punkt"].contains { result.text.lowercased().contains($0) }
        let lastWordEnd =
          tokens.last(where: { !marks.contains($0.token.trimmingCharacters(in: .whitespaces)) })?.end ?? 0
        print(
          "PUNCT-AUDIO voice=\(voice.label) sentence=\(index + 1) durMs=\(ms(audioEnd)) "
            + "lastWordEndMs=\(ms(lastWordEnd)) raw=\(result.text)")
        for (i, token) in tokens.enumerated() {
          let mark = token.token.trimmingCharacters(in: .whitespaces)
          guard marks.contains(mark) else { continue }
          let isFinal = i == tokens.count - 1
          let kind = sentence.kind == "guessed" ? "guessed" : sentence.kind
          let before = i > 0 ? ms(token.start - tokens[i - 1].end) : 0
          let after = isFinal ? ms(audioEnd - token.end) : ms(tokens[i + 1].start - token.end)
          let tokenMs = ms(token.end - token.start)
          var tail: Int?
          var tailText = "-"
          if isFinal {
            let lastWord = tokens[..<i].last(where: { !marks.contains($0.token.trimmingCharacters(in: .whitespaces)) })
            tail = ms(audioEnd - (lastWord?.end ?? 0))
            tailText = "\(tail!)"
          }
          samples.append(
            Sample(kind: kind, mark: mark, pos: isFinal ? "final" : "mid", token: tokenMs, after: after, tail: tail))
          print(
            "PUNCT voice=\(voice.label) kind=\(kind) mark=\(mark) pos=\(isFinal ? "final" : "mid") "
              + "tokenMs=\(tokenMs) gapBeforeMs=\(before) gapAfterMs=\(after) "
              + "prevWordEndToAudioEndMs=\(tailText) rawHasWord=\(rawHasWord)")
        }
      }
    }

    func stats(_ values: [Int]) -> String {
      guard !values.isEmpty else { return "-" }
      let sorted = values.sorted()
      return "\(sorted.first!)/\(sorted[sorted.count / 2])/\(sorted.last!)"
    }
    var groups: [String: [Sample]] = [:]
    for s in samples { groups["\(s.kind) mark=\(s.mark) pos=\(s.pos)", default: []].append(s) }
    for key in groups.keys.sorted() {
      let g = groups[key]!
      print(
        "PUNCT-SUMMARY \(key) count=\(g.count) gapAfterMs(min/med/max)=\(stats(g.map(\.after))) "
          + "tokenMs=\(stats(g.map(\.token))) prevWordEndToAudioEndMs=\(stats(g.compactMap(\.tail)))")
    }
  }

  private static func say(_ text: String, voice: String, rate: Int?, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    var args = ["-v", voice]
    if let rate { args += ["-r", String(rate)] }
    args += ["-o", url.path, "--data-format=LEI16@16000", text]
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "LiveDictationPilotTests", code: Int(process.terminationStatus))
    }
  }
}
