import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// SPIKE (spike/parakeet-booster-aliases): does passing `(not "...")` forms as booster aliases make
/// the CTC booster propose the term? Opt-in via build/spike/enabled. Output: build/spike/results.tsv.
@Suite("Parakeet booster alias spike (opt-in)", .serialized)
struct ParakeetBoosterAliasSpikeTests {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
  private static let spike = root.appendingPathComponent("build/spike")
  private static var enabled: Bool {
    FileManager.default.fileExists(atPath: spike.appendingPathComponent("enabled").path)
  }

  @Test("arms x files", .enabled(if: enabled))
  func run() async throws {
    try await ModelManager.shared.ensureReady(.parakeetUltra)
    try await LocalSpeechService.shared.initializeModel(.parakeetUltra)
    let glossaryA = "Lasègue"
    let glossaryB = "Lasègue (not \"Laseg\", \"Lasse\", \"Lasek\")"
    var out = "arm\tfile\ttext\n"

    func decode(_ file: String, _ lang: String, glossary: String, aliases: Bool, terms: [String])
      async throws -> String
    {
      ParakeetBoosterSpike.glossaryText = glossary
      ParakeetBoosterSpike.aliases = aliases
      return try await LocalSpeechService.shared.transcribe(
        audioURL: Self.spike.appendingPathComponent(file), language: lang, vocabulary: terms)
    }

    let arms: [(String, String, Bool)] = [
      ("A/no-alias", glossaryA, false), ("A/alias", glossaryA, true),
      ("B/no-alias", glossaryB, false), ("B/alias", glossaryB, true),
    ]
    for (name, glossary, aliases) in arms {
      print("SPIKEARM \(name)")
      for (file, lang) in [("en.wav", "en"), ("de.wav", "de")] {
        let text = try await decode(file, lang, glossary: glossary, aliases: aliases, terms: ["Lasègue"])
        out += "\(name)\t\(file)\t\(text.replacingOccurrences(of: "\n", with: "⏎"))\n"
        print("SPIKE\t\(name)\t\(file)\t\(text)")
      }
    }

    // Corpus: false-boost check. Same four-term glossary the benchmark uses, plus Lasègue.
    let base = ["GdB", "VersMedV", "ADL", "Merkzeichen"]
    let corpusDir = Self.spike.appendingPathComponent("corpus")
    let wavs = ((try? FileManager.default.contentsOfDirectory(atPath: corpusDir.path)) ?? [])
      .filter { $0.hasSuffix(".wav") }.sorted()
    var diffs = 0
    var rows = ""
    for wav in wavs {
      var texts: [String] = []
      for (glossary, aliases) in [(glossaryB, false), (glossaryB, true)] {
        let t = try await decode(
          "corpus/\(wav)", "de", glossary: base.joined(separator: "\n") + "\n" + glossary,
          aliases: aliases, terms: base + ["Lasègue"])
        texts.append(t)
      }
      let hit = texts.contains { $0.contains("Lasègue") }
      let differ = texts[0] != texts[1]
      if differ { diffs += 1 }
      rows += "corpus\t\(wav)\tdiffer=\(differ)\tlasegueInOutput=\(hit)\tnoAlias=\(texts[0].replacingOccurrences(of: "\n", with: "⏎"))\talias=\(texts[1].replacingOccurrences(of: "\n", with: "⏎"))\n"
    }
    out += rows + "corpus-summary\tfiles=\(wavs.count)\tdiffering=\(diffs)\n"
    print("SPIKE corpus files=\(wavs.count) differing=\(diffs)")
    print("SPIKE lasegueHitsInCorpus=\(rows.components(separatedBy: "lasegueInOutput=true").count - 1)")
  }
}
