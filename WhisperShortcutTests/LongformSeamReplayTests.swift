import Foundation
import Testing
@testable import WhisperShortcut_AppStore

// MARK: - Scoring

/// How much live cutting costs against one decode of the whole file.
///
/// Words are `DictationBenchmarkScoring.words` (the dictation benchmark's normalisation).
/// A seam index is the word index in the live text where the next piece starts. A differing
/// run of the live-vs-whole LCS is one error, and it is seam-attributable when that run lies
/// within one word of a seam index. The decision rule is at most one such error per text;
/// the summary counts texts that have more.
enum LongformSeamReplay {

  struct WordError: Equatable {
    /// Half-open range in the whole-file word array. Empty when the run is live-only.
    let wholeRange: Range<Int>
    /// Half-open range in the live word array. Empty when the run is a deletion.
    let liveRange: Range<Int>
    let seamAttributable: Bool
  }

  struct CaseReport: Equatable {
    let id: String
    let type: String
    let pieces: Int
    let silent: Int
    let seams: [Int]
    let liveOnlyErrors: Int
    let seamErrors: Int
    let seamLines: [String]
    /// Rounded word accuracy against the expected text. Nil unless the case is `read`.
    let liveAccuracy: Double?
    let wholeAccuracy: Double?

    var delta: Double? {
      guard let liveAccuracy, let wholeAccuracy else { return nil }
      return wholeAccuracy - liveAccuracy
    }
  }

  struct Summary: Equatable {
    let meanDelta: Double?
    let seamErrors: Int
    let casesWithMoreThanOneSeamError: Int
  }

  /// `(expected words − edit distance) / expected words`, rounded to three decimals the way
  /// `DictationBenchmarkScoring.metrics` rounds.
  static func wordAccuracy(output: String, expected: String) -> Double {
    let expectedWords = DictationBenchmarkScoring.words(expected)
    guard !expectedWords.isEmpty else { return 1 }
    let distance = LiveDictation.editDistance(expectedWords, DictationBenchmarkScoring.words(output))
    let raw = Double(expectedWords.count - distance) / Double(expectedWords.count)
    return (raw * 1000).rounded() / 1000
  }

  /// LCS diff. Each maximal run of non-matching words is one error.
  static func wordErrors(whole: [String], live: [String], seams: [Int]) -> [WordError] {
    diffRuns(whole, live).map { run in
      WordError(
        wholeRange: run.whole, liveRange: run.live,
        seamAttributable: liesWithinOneWord(of: seams, liveRange: run.live))
    }
  }

  static func analyze(wholeText: String, liveText: String, seams: [Int]) -> (
    liveOnlyErrors: Int, seamErrors: Int, seamLines: [String]
  ) {
    let whole = DictationBenchmarkScoring.words(wholeText)
    let live = DictationBenchmarkScoring.words(liveText)
    let errors = wordErrors(whole: whole, live: live, seams: seams)
    let seamLines = errors.filter(\.seamAttributable).map { seamQuote(whole: whole, live: live, error: $0) }
    return (errors.count, seamLines.count, seamLines)
  }

  /// The changed words, with up to three words on either side, marked in brackets.
  static func quote(words: [String], range: Range<Int>, context: Int = 3) -> String {
    let lower = min(max(range.lowerBound, 0), words.count)
    let upper = min(max(range.upperBound, lower), words.count)
    let start = max(0, lower - context)
    let end = min(words.count, upper + context)
    let pre = words[start..<lower].joined(separator: " ")
    let mid = words[lower..<upper].joined(separator: " ")
    let post = words[upper..<end].joined(separator: " ")
    return [pre, "[\(mid)]", post].filter { !$0.isEmpty }.joined(separator: " ")
  }

  static func seamQuote(whole: [String], live: [String], error: WordError) -> String {
    "whole: «\(quote(words: whole, range: error.wholeRange))» / live: «\(quote(words: live, range: error.liveRange))»"
  }

  static func summary(_ cases: [CaseReport]) -> Summary {
    let deltas = cases.compactMap(\.delta)
    let mean: Double?
    if deltas.isEmpty {
      mean = nil
    } else {
      mean = (deltas.reduce(0, +) / Double(deltas.count) * 1000).rounded() / 1000
    }
    return Summary(
      meanDelta: mean,
      seamErrors: cases.map(\.seamErrors).reduce(0, +),
      casesWithMoreThanOneSeamError: cases.filter { $0.seamErrors > 1 }.count)
  }

  static func summaryLine(_ cases: [CaseReport]) -> String {
    let row = summary(cases)
    let mean = row.meanDelta.map { String(format: "%+.3f", $0) } ?? "-"
    return "summary\tmeanDelta=\(mean)\tseamErrors=\(row.seamErrors)\t"
      + "casesWithMoreThanOneSeamError=\(row.casesWithMoreThanOneSeamError)"
  }

  static func render(
    model: String, cases: [CaseReport], skipped: [(id: String, type: String)] = []
  ) -> String {
    var lines = ["model \(model)"]
    for item in cases {
      lines.append("")
      let seamText = item.seams.isEmpty ? "-" : item.seams.map(String.init).joined(separator: ",")
      lines.append(
        "\(item.id)\t\(item.type)\tpieces=\(item.pieces)\tsilent=\(item.silent)\tseams=\(seamText)")
      if let live = item.liveAccuracy, let whole = item.wholeAccuracy, let delta = item.delta {
        lines.append(
          String(format: "  wordAccuracy live=%.3f whole=%.3f delta=%+.3f", live, whole, delta))
      }
      lines.append("  liveOnlyErrors=\(item.liveOnlyErrors) seamErrors=\(item.seamErrors)")
      for quote in item.seamLines {
        lines.append("  seam \(quote)")
      }
    }
    if !skipped.isEmpty {
      lines.append("")
      for item in skipped {
        lines.append("skipped\t\(item.id)\t\(item.type)\tno recording")
      }
    }
    lines.append("")
    lines.append(summaryLine(cases))
    return lines.joined(separator: "\n")
  }

  /// A non-empty live run is within one word when any of its word indices is. A deletion sits
  /// in the gap before `liveRange.lowerBound`, and that gap is within one word of a seam.
  static func liesWithinOneWord(of seams: [Int], liveRange: Range<Int>) -> Bool {
    for seam in seams {
      if liveRange.isEmpty {
        if abs(liveRange.lowerBound - seam) <= 1 { return true }
      } else {
        let first = liveRange.lowerBound
        let last = liveRange.upperBound - 1
        if first <= seam + 1 && last >= seam - 1 { return true }
      }
    }
    return false
  }

  /// One LCS alignment. Consecutive non-matching words are a single run. An empty range is the
  /// gap where the other side has the words.
  private static func diffRuns(_ whole: [String], _ live: [String]) -> [(whole: Range<Int>, live: Range<Int>)] {
    let n = whole.count
    let m = live.count
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    if n > 0 && m > 0 {
      for i in 1...n {
        for j in 1...m {
          if whole[i - 1] == live[j - 1] {
            dp[i][j] = dp[i - 1][j - 1] + 1
          } else {
            dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
          }
        }
      }
    }

    var i = n
    var j = m
    var steps: [(wholeIndex: Int?, liveIndex: Int?)] = []
    steps.reserveCapacity(n + m)
    while i > 0 || j > 0 {
      if i > 0, j > 0, whole[i - 1] == live[j - 1] {
        steps.append((i - 1, j - 1))
        i -= 1
        j -= 1
      } else if j > 0, i == 0 || dp[i][j - 1] >= dp[i - 1][j] {
        steps.append((nil, j - 1))
        j -= 1
      } else {
        steps.append((i - 1, nil))
        i -= 1
      }
    }
    steps.reverse()

    var runs: [(whole: Range<Int>, live: Range<Int>)] = []
    var inRun = false
    var wholeLower = 0
    var wholeUpper = 0
    var liveLower = 0
    var liveUpper = 0
    var nextWhole = 0
    var nextLive = 0
    func close() {
      guard inRun else { return }
      runs.append((wholeLower..<wholeUpper, liveLower..<liveUpper))
      inRun = false
    }
    for step in steps {
      if let wholeIndex = step.wholeIndex, let liveIndex = step.liveIndex {
        close()
        nextWhole = wholeIndex + 1
        nextLive = liveIndex + 1
        continue
      }
      if !inRun {
        inRun = true
        wholeLower = nextWhole
        wholeUpper = nextWhole
        liveLower = nextLive
        liveUpper = nextLive
      }
      if let wholeIndex = step.wholeIndex {
        wholeUpper = wholeIndex + 1
        nextWhole = wholeIndex + 1
      }
      if let liveIndex = step.liveIndex {
        liveUpper = liveIndex + 1
        nextLive = liveIndex + 1
      }
    }
    close()
    return runs
  }
}

// MARK: - Unit tests

@Suite("Long-form seam replay scoring")
struct LongformSeamReplayScoringTests {

  @Test("one error at a seam, one far away, one spanning a seam")
  func seamAttribution() {
    // At the seam: the substituted word is the first word of the next piece (index 2).
    let atSeam = LongformSeamReplay.wordErrors(
      whole: ["aa", "bb", "cc", "dd", "ee", "ff"],
      live: ["aa", "bb", "cx", "dd", "ee", "ff"],
      seams: [2])
    #expect(atSeam.count == 1)
    #expect(atSeam[0].seamAttributable)
    #expect(atSeam[0].liveRange == 2..<3)

    // One word before the seam is still within one word. Two words before is not.
    let oneAway = LongformSeamReplay.wordErrors(
      whole: ["aa", "bb", "cc", "dd", "ee", "ff"],
      live: ["aa", "bb", "cx", "dd", "ee", "ff"],
      seams: [3])
    #expect(oneAway.count == 1)
    #expect(oneAway[0].seamAttributable)
    let twoAway = LongformSeamReplay.wordErrors(
      whole: ["aa", "bb", "cc", "dd", "ee", "ff"],
      live: ["aa", "bx", "cc", "dd", "ee", "ff"],
      seams: [3])
    #expect(twoAway.count == 1)
    #expect(!twoAway[0].seamAttributable)

    // A deletion in the gap at the seam counts; a deletion two words away does not.
    let deletedAtSeam = LongformSeamReplay.wordErrors(
      whole: ["aa", "bb", "cc", "dd", "ee"],
      live: ["aa", "bb", "dd", "ee"],
      seams: [2])
    #expect(deletedAtSeam.count == 1)
    #expect(deletedAtSeam[0].liveRange.isEmpty)
    #expect(deletedAtSeam[0].seamAttributable)
    let deletedFar = LongformSeamReplay.wordErrors(
      whole: ["aa", "xx", "bb", "cc", "dd", "ee"],
      live: ["aa", "bb", "cc", "dd", "ee"],
      seams: [3])
    #expect(deletedFar.count == 1)
    #expect(!deletedFar[0].seamAttributable)

    // Spanning: one run covers the last word of one piece and the first of the next.
    let spanning = LongformSeamReplay.wordErrors(
      whole: ["aa", "bb", "cc", "dd", "ee", "ff", "gg"],
      live: ["aa", "bb", "xx", "yy", "ee", "ff", "gg"],
      seams: [3])
    #expect(spanning.count == 1)
    #expect(spanning[0].wholeRange == 2..<4)
    #expect(spanning[0].liveRange == 2..<4)
    #expect(spanning[0].seamAttributable)
    #expect(
      LongformSeamReplay.seamQuote(
        whole: ["aa", "bb", "cc", "dd", "ee", "ff", "gg"],
        live: ["aa", "bb", "xx", "yy", "ee", "ff", "gg"],
        error: spanning[0])
        == "whole: «aa bb [cc dd] ee ff gg» / live: «aa bb [xx yy] ee ff gg»")

    // All three in one text, so each run stays one error and the far one is not attributed.
    // Index: 0 aa, 1 bx (far), 2 cc, 3 dd, 4 ee, 5 xx, 6 yy (spans seam 6), 7 hh … 10 kx (at seam 10).
    let whole = ["aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii", "jj", "kk", "ll"]
    let live = ["aa", "bx", "cc", "dd", "ee", "xx", "yy", "hh", "ii", "jj", "kx", "ll"]
    let errors = LongformSeamReplay.wordErrors(whole: whole, live: live, seams: [6, 10])
    #expect(errors.count == 3)
    #expect(errors.map(\.seamAttributable) == [false, true, true])
    #expect(errors.map(\.liveRange) == [1..<2, 5..<7, 10..<11])
    let seamLines = errors.filter(\.seamAttributable).map {
      LongformSeamReplay.seamQuote(whole: whole, live: live, error: $0)
    }
    #expect(seamLines == [
      "whole: «cc dd ee [ff gg] hh ii jj» / live: «cc dd ee [xx yy] hh ii jj»",
      "whole: «hh ii jj [kk] ll» / live: «hh ii jj [kx] ll»",
    ])
  }

  @Test("word accuracy uses the benchmark word normalisation")
  func wordAccuracy() {
    #expect(
      LongformSeamReplay.wordAccuracy(output: "Gangbild, geht weiter.", expected: "Gangbild geht weiter")
        == 1)
    #expect(
      LongformSeamReplay.wordAccuracy(output: "alpha beta WRONG delta", expected: "alpha beta gamma delta")
        == 0.75)
  }

  @Test("summary row is mean delta, total seam errors, and texts over the one-error rule")
  func summaryRow() {
    let one = LongformSeamReplay.CaseReport(
      id: "a", type: "read", pieces: 3, silent: 0, seams: [4],
      liveOnlyErrors: 2, seamErrors: 1, seamLines: [],
      liveAccuracy: 0.5, wholeAccuracy: 1)
    let two = LongformSeamReplay.CaseReport(
      id: "b", type: "read", pieces: 4, silent: 0, seams: [2, 8],
      liveOnlyErrors: 3, seamErrors: 2, seamLines: [],
      liveAccuracy: 0.75, wholeAccuracy: 1)
    let composed = LongformSeamReplay.CaseReport(
      id: "c", type: "composed", pieces: 2, silent: 1, seams: [5],
      liveOnlyErrors: 0, seamErrors: 0, seamLines: [],
      liveAccuracy: nil, wholeAccuracy: nil)
    let text = LongformSeamReplay.render(
      model: "parakeet-ultra", cases: [one, two, composed], skipped: [("lf-held-hand", "heldOut")])
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.last == "summary\tmeanDelta=+0.375\tseamErrors=3\tcasesWithMoreThanOneSeamError=1")
    #expect(lines.contains("skipped\tlf-held-hand\theldOut\tno recording"))
    #expect(lines.contains("a\tread\tpieces=3\tsilent=0\tseams=4"))
    #expect(lines.contains("  wordAccuracy live=0.500 whole=1.000 delta=+0.500"))
  }
}

// MARK: - Opt-in replay

/// Whole-file decode versus Dictate Live's pieces, on the long-form recordings.
///
/// Run it with `scripts/longform-replay.sh`, not by hand. Enabled by
/// `build/longform-replay/config.json` while that file is younger than six hours, for the same
/// reason as `DictationBenchmarkTests`: a shell export does not reach this sandboxed host, and a
/// leftover config must not start a model download inside `run-tests.sh`. The script removes the
/// config on exit.
///
/// Each recording is transcribed once (`finishPiece`, spokenOnly) and again as live pieces
/// (`LivePieceSplitter` / `RotationPolicy.live`, the same `finishPiece` + `LiveChunkJoiner` path
/// the dictation benchmark's real tier uses).
@Suite("Long-form seam replay (opt-in)", .serialized)
struct LongformSeamReplayTests {

  struct Config: Decodable {
    let model: String
    let audioDir: String
    let corpus: String
  }

  struct CorpusFile: Decodable {
    struct Case: Decodable {
      let id: String
      let mode: String
      let heldOut: Bool
      let expected: String?
    }
    let glossary: [String]?
    let cases: [Case]
  }

  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
  private static let configURL = repoRoot.appendingPathComponent("build/longform-replay/config.json")

  private static var configIsFresh: Bool {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path),
      let modified = attributes[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(modified) < 6 * 3600
  }

  @Test(
    "Long-form recordings, whole file versus live pieces",
    .enabled(if: configIsFresh, "Run scripts/longform-replay.sh to enable"),
    .timeLimit(.minutes(30)))
  func replay() async throws {
    setvbuf(stdout, nil, _IONBF, 0)
    let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: Self.configURL))
    let corpus = try JSONDecoder().decode(CorpusFile.self, from: Data(contentsOf: URL(fileURLWithPath: config.corpus)))
    let glossary = corpus.glossary ?? []
    let model = try #require(OfflineModelType(rawValue: config.model), "unknown model \(config.model)")
    try await ModelManager.shared.ensureReady(model)
    try await LocalSpeechService.shared.initializeModel(model)

    let audioDir = URL(fileURLWithPath: config.audioDir, isDirectory: true)
    let workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("longform-replay-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    var reports: [LongformSeamReplay.CaseReport] = []
    var skipped: [(id: String, type: String)] = []
    var seen: Set<String> = []
    for item in corpus.cases {
      seen.insert(item.id)
      let wav = audioDir.appendingPathComponent("\(item.id).wav")
      guard FileManager.default.fileExists(atPath: wav.path) else {
        skipped.append((item.id, Self.typeLabel(item)))
        continue
      }
      print("REPLAY-PROGRESS\t\(item.id)")
      reports.append(try await Self.score(
        item, wav: wav, workDir: workDir, model: model, glossary: glossary))
    }
    if let names = try? FileManager.default.contentsOfDirectory(atPath: audioDir.path) {
      for name in names.filter({ $0.hasSuffix(".wav") }).sorted() {
        let id = String(name.dropLast(4))
        guard !seen.contains(id) else { continue }
        print("REPLAY-PROGRESS\t\(id)")
        let wav = audioDir.appendingPathComponent(name)
        let placeholder = CorpusFile.Case(id: id, mode: "unlisted", heldOut: false, expected: nil)
        reports.append(try await Self.score(
          placeholder, wav: wav, workDir: workDir, model: model, glossary: glossary))
      }
    }

    let report = LongformSeamReplay.render(model: config.model, cases: reports, skipped: skipped)
    for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
      print("REPLAY\t\(line)")
    }
  }

  private static func typeLabel(_ item: CorpusFile.Case) -> String {
    item.heldOut ? "heldOut" : item.mode
  }

  /// The dictation benchmark's real-tier decode: Parakeet with `spokenMarksOnly`, or Whisper
  /// with the glossary as a prompt. No speech is an empty piece.
  private static func rawTranscript(url: URL, model: OfflineModelType, glossary: [String]) async throws -> String {
    do {
      if model.engine == .parakeet {
        return try await LocalSpeechService.shared.transcribe(
          audioURL: url, language: "de", vocabulary: glossary, spokenMarksOnly: true)
      }
      return try await LocalSpeechService.shared.transcribe(
        audioURL: url, language: "de", prompt: glossary.joined(separator: ", "),
        vocabulary: [], spokenMarksOnly: true)
    } catch TranscriptionError.noSpeechDetected {
      return ""
    }
  }

  private static func score(
    _ item: CorpusFile.Case, wav: URL, workDir: URL, model: OfflineModelType, glossary: [String]
  ) async throws -> LongformSeamReplay.CaseReport {
    try Task.checkCancellation()
    let wholeRaw = try await rawTranscript(url: wav, model: model, glossary: glossary)
    let wholeText = LiveDictation.finishPiece(wholeRaw, mode: .spokenOnly, timedMarks: true)

    let pieces = try LivePieceSplitter.split(wav, into: workDir)
    var output = ""
    var joiner = LiveChunkJoiner()
    joiner.holdsPeriods = false
    joiner.seed(.unknown)
    var seams: [Int] = []
    var transcribed = 0
    for piece in pieces where !piece.isSilent {
      try Task.checkCancellation()
      // The seam is the first word of this piece. An empty piece adds no words, so it does not
      // move the index; a leading empty piece is not a boundary in the text.
      if transcribed > 0 {
        let at = DictationBenchmarkScoring.words(output).count
        if at > 0, seams.last != at {
          seams.append(at)
        }
      }
      transcribed += 1
      let raw = try await rawTranscript(url: piece.url, model: model, glossary: glossary)
      output += joiner.next(LiveDictation.finishPiece(raw, mode: .spokenOnly, timedMarks: true))
    }
    output += joiner.finish()

    let diff = LongformSeamReplay.analyze(wholeText: wholeText, liveText: output, seams: seams)
    let read = item.mode == "read" ? item.expected : nil
    return LongformSeamReplay.CaseReport(
      id: item.id, type: typeLabel(item), pieces: pieces.count,
      silent: pieces.filter(\.isSilent).count, seams: seams,
      liveOnlyErrors: diff.liveOnlyErrors, seamErrors: diff.seamErrors, seamLines: diff.seamLines,
      liveAccuracy: read.map { LongformSeamReplay.wordAccuracy(output: output, expected: $0) },
      wholeAccuracy: read.map { LongformSeamReplay.wordAccuracy(output: wholeText, expected: $0) })
  }
}
