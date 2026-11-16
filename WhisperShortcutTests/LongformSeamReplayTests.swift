import AVFoundation
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
    /// Longest piece that was transcribed, in seconds. Nil when every piece was silent.
    let maxPieceSeconds: Double?
    let seams: [Int]
    let liveOnlyErrors: Int
    let seamErrors: Int
    let seamLines: [String]
    let liveWords: Int
    /// Live words whose index is within 1 of a seam. The chance an error lands near a seam.
    let nearSeamWords: Int
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
    /// Seam errors per 100 live words, pooled across cases. Nil when there are no live words.
    let seamErrorsPer100Words: Double?
    /// Share of live words within 1 word of a seam, pooled. Nil when there are no live words.
    let nearSeamWordShare: Double?
  }

  /// Why `LivePieceSplitter` cuts more often than the recorder. The cut rule is unchanged; see the
  /// comment on `LivePieceSplitter`.
  static let overCutNote =
    "The splitter scores a raw 50 ms RMS against a fixed -45 dB (from 5 s, the soft rule uses two 0.2 s decisions under -35 dB). "
    + "The recorder scores AVAudioRecorder.averagePower, one 50 ms metering tick, against a noise floor that drops immediately and rises by at most 0.05 dB per 0.2 s sample. "
    + "The threshold is that floor plus 10 dB, clamped from -45 to -30 dB, and the soft rule adds another 10 dB capped at -20 dB. "
    + "On these sessions the floor sat near -60 dB, so the clamp held both on -45 dB and a soft line of -35 dB. "
    + "A raw RMS of the benchmark wav is quieter than that live meter, so the same numbers cut more often. "
    + "The splitter is unchanged: the noise-floor clamp would not move the threshold off -45 dB here, and matching averagePower is not a small correction."

  static let chanceNote =
    "nearSeamWordShare is the share of live words within 1 word of a seam. An error lands near a seam by luck at that rate."

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
    liveOnlyErrors: Int, seamErrors: Int, seamLines: [String], liveWords: Int, nearSeamWords: Int
  ) {
    let whole = DictationBenchmarkScoring.words(wholeText)
    let live = DictationBenchmarkScoring.words(liveText)
    let errors = wordErrors(whole: whole, live: live, seams: seams)
    let seamLines = errors.filter(\.seamAttributable).map { seamQuote(whole: whole, live: live, error: $0) }
    return (
      errors.count, seamLines.count, seamLines, live.count,
      nearSeamWordCount(liveWordCount: live.count, seams: seams))
  }

  /// Live words whose index is within 1 of a seam index. That is the chance an error is attributed
  /// to a seam: the attribution window is the same ±1 word.
  static func nearSeamWordCount(liveWordCount: Int, seams: [Int]) -> Int {
    guard liveWordCount > 0, !seams.isEmpty else { return 0 }
    var count = 0
    for index in 0..<liveWordCount where seams.contains(where: { abs(index - $0) <= 1 }) {
      count += 1
    }
    return count
  }

  static func seamRates(seamErrors: Int, liveWords: Int, nearSeamWords: Int) -> (
    per100: Double?, share: Double?
  ) {
    guard liveWords > 0 else { return (nil, nil) }
    return (
      rounded3(Double(seamErrors) / Double(liveWords) * 100),
      rounded3(Double(nearSeamWords) / Double(liveWords)))
  }

  private static func rounded3(_ value: Double) -> Double {
    (value * 1000).rounded() / 1000
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
      mean = rounded3(deltas.reduce(0, +) / Double(deltas.count))
    }
    let seamErrors = cases.map(\.seamErrors).reduce(0, +)
    let liveWords = cases.map(\.liveWords).reduce(0, +)
    let nearSeamWords = cases.map(\.nearSeamWords).reduce(0, +)
    let rates = seamRates(seamErrors: seamErrors, liveWords: liveWords, nearSeamWords: nearSeamWords)
    return Summary(
      meanDelta: mean,
      seamErrors: seamErrors,
      casesWithMoreThanOneSeamError: cases.filter { $0.seamErrors > 1 }.count,
      seamErrorsPer100Words: rates.per100,
      nearSeamWordShare: rates.share)
  }

  static func summaryLine(_ cases: [CaseReport]) -> String {
    let row = summary(cases)
    let mean = row.meanDelta.map { String(format: "%+.3f", $0) } ?? "-"
    return "summary\tmeanDelta=\(mean)\tseamErrors=\(row.seamErrors)\t"
      + "casesWithMoreThanOneSeamError=\(row.casesWithMoreThanOneSeamError)\t"
      + "seamErrorsPer100Words=\(formatRate(row.seamErrorsPer100Words))\t"
      + "nearSeamWordShare=\(formatRate(row.nearSeamWordShare))"
  }

  static func render(
    model: String, cuts: String, policy: String? = nil, cases: [CaseReport],
    skipped: [(id: String, type: String, reason: String)] = []
  ) -> String {
    var lines = ["model \(model)", "cuts \(cuts)"]
    if let policy { lines.append("policy \(policy)") }
    lines.append("note \(overCutNote)")
    lines.append("chance \(chanceNote)")
    for item in cases {
      lines.append("")
      let seamText = item.seams.isEmpty ? "-" : item.seams.map(String.init).joined(separator: ",")
      let maxPiece = item.maxPieceSeconds.map { String(format: "%.2f", $0) } ?? "-"
      lines.append(
        "\(item.id)\t\(item.type)\tpieces=\(item.pieces)\tsilent=\(item.silent)\t"
          + "maxPieceS=\(maxPiece)\tseams=\(seamText)")
      if let live = item.liveAccuracy, let whole = item.wholeAccuracy, let delta = item.delta {
        lines.append(
          String(format: "  wordAccuracy live=%.3f whole=%.3f delta=%+.3f", live, whole, delta))
      }
      let rates = seamRates(
        seamErrors: item.seamErrors, liveWords: item.liveWords, nearSeamWords: item.nearSeamWords)
      lines.append(
        "  liveOnlyErrors=\(item.liveOnlyErrors) seamErrors=\(item.seamErrors) "
          + "seamErrorsPer100Words=\(formatRate(rates.per100)) "
          + "nearSeamWordShare=\(formatRate(rates.share))")
      for quote in item.seamLines {
        lines.append("  seam \(quote)")
      }
    }
    if !skipped.isEmpty {
      lines.append("")
      for item in skipped {
        lines.append("skipped\t\(item.id)\t\(item.type)\t\(item.reason)")
      }
    }
    lines.append("")
    lines.append(summaryLine(cases))
    return lines.joined(separator: "\n")
  }

  static func formatRate(_ value: Double?) -> String {
    value.map { String(format: "%.3f", $0) } ?? "-"
  }

  static func describe(policy: ChunkedDictateRecorder.RotationPolicy) -> String {
    guard let after = policy.softCutAfter else { return "liveWithoutSoftCut" }
    return "live softAfter=\(formatPolicy(after)) "
      + "softSilence=\(formatPolicy(policy.softCutSilenceDuration)) "
      + "softBoost=\(formatPolicy(Double(policy.softCutThresholdBoostDB)))"
  }

  private static func formatPolicy(_ value: Double) -> String {
    String(format: "%g", value)
  }

  // MARK: - Real cut points

  /// The benchmark wav starts this long before the `LIVE-DICTATE: Starting` line
  /// (`record_longform.py` `PAD_S`).
  static let recordingLeadIn: TimeInterval = 0.5
  /// A `Silent piece skipped` line this soon after a rotation belongs to that piece. Later, it is
  /// the tail. Same window as `piece_metrics` in `record_longform.py`.
  static let silentSkipWindow: TimeInterval = 0.1

  enum CutLogError: Error, Equatable {
    case noStartingLine
    case unparseableTimestamps

    var reason: String {
      switch self {
      case .noStartingLine: return "no LIVE-DICTATE: Starting line"
      case .unparseableTimestamps: return "pieces log timestamps are unparseable"
      }
    }
  }

  struct SessionCuts: Equatable {
    /// Seconds from the start of the wav. Each value is a rotation time plus `recordingLeadIn`.
    let cuts: [Double]
    /// One flag per piece, including the tail after the last cut. `cuts.count + 1` entries.
    let silent: [Bool]
  }

  /// Rotation times from a `pieces.log`, mapped onto the wav. The last `LIVE-DICTATE: Starting`
  /// line is the origin. A log with no rotation is one piece, the whole file.
  static func parseSessionCuts(_ log: String) throws -> SessionCuts {
    let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let starting = lines.filter { $0.contains("LIVE-DICTATE: Starting") }
    guard let startingLine = starting.last else { throw CutLogError.noStartingLine }
    guard let start = logInstant(startingLine) else { throw CutLogError.unparseableTimestamps }

    var rotations: [TimeInterval] = []
    var silentRotated = Set<Int>()
    var tailSilent = false
    for line in lines {
      let isRotation = line.contains("Rotated dictate chunk")
      let isSkip = line.contains("Silent piece skipped")
      guard isRotation || isSkip else { continue }
      guard let instant = logInstant(line) else { throw CutLogError.unparseableTimestamps }
      let relative = instant - start
      guard relative >= 0 else { continue }
      if isRotation {
        rotations.append(relative)
      } else if let last = rotations.last, relative - last <= silentSkipWindow {
        silentRotated.insert(rotations.count - 1)
      } else {
        tailSilent = true
      }
    }

    var silent = Array(repeating: false, count: rotations.count + 1)
    for index in silentRotated { silent[index] = true }
    silent[rotations.count] = tailSilent
    return SessionCuts(cuts: rotations.map { $0 + recordingLeadIn }, silent: silent)
  }

  /// Half-open pieces covering `duration` seconds. A cut that does not move forward is dropped,
  /// and the silent flag stays with the piece index it was parsed for.
  static func pieceSpans(cuts: [Double], silent: [Bool], duration: Double) -> [(
    start: Double, end: Double, isSilent: Bool
  )] {
    let length = max(duration, 0)
    var edges = [0.0]
    for cut in cuts {
      edges.append(min(max(cut, 0), length))
    }
    edges.append(length)
    for index in 1..<edges.count where edges[index] < edges[index - 1] {
      edges[index] = edges[index - 1]
    }
    var spans: [(start: Double, end: Double, isSilent: Bool)] = []
    for index in 0..<(edges.count - 1) where edges[index + 1] > edges[index] {
      let isSilent = index < silent.count ? silent[index] : false
      spans.append((edges[index], edges[index + 1], isSilent))
    }
    return spans
  }

  /// Seconds since 1970 for a unified-log timestamp at the start of `line` (`YYYY-MM-DD HH:MM:SS.fff`).
  /// The zone is fixed so a difference does not depend on the machine's time zone.
  static func logInstant(_ line: String) -> TimeInterval? {
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(2)
    guard fields.count == 2 else { return nil }
    let date = fields[0].split(separator: "-")
    let clock = fields[1].split(separator: ":")
    guard date.count == 3, clock.count == 3,
      let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
      let hour = Int(clock[0]), let minute = Int(clock[1])
    else { return nil }
    let secondField = clock[2].split(separator: ".", omittingEmptySubsequences: false)
    guard let second = Int(secondField[0]), (0..<60).contains(second) else { return nil }
    var fraction = 0.0
    if secondField.count > 1 {
      let digits = String(secondField[1])
      guard !digits.isEmpty, let number = Double(digits), digits.allSatisfy(\.isNumber) else { return nil }
      fraction = number / pow(10, Double(digits.count))
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    guard let instant = calendar.date(from: components) else { return nil }
    return instant.timeIntervalSince1970 + fraction
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
      id: "a", type: "read", pieces: 3, silent: 0, maxPieceSeconds: 6.5, seams: [4],
      liveOnlyErrors: 2, seamErrors: 1, seamLines: [], liveWords: 40, nearSeamWords: 4,
      liveAccuracy: 0.5, wholeAccuracy: 1)
    let two = LongformSeamReplay.CaseReport(
      id: "b", type: "read", pieces: 4, silent: 0, maxPieceSeconds: 8, seams: [2, 8],
      liveOnlyErrors: 3, seamErrors: 2, seamLines: [], liveWords: 40, nearSeamWords: 8,
      liveAccuracy: 0.75, wholeAccuracy: 1)
    let composed = LongformSeamReplay.CaseReport(
      id: "c", type: "composed", pieces: 2, silent: 1, maxPieceSeconds: nil, seams: [5],
      liveOnlyErrors: 0, seamErrors: 0, seamLines: [], liveWords: 20, nearSeamWords: 0,
      liveAccuracy: nil, wholeAccuracy: nil)
    let text = LongformSeamReplay.render(
      model: "parakeet-ultra", cuts: "splitter",
      policy: "live softAfter=5 softSilence=0.4 softBoost=10",
      cases: [one, two, composed], skipped: [("lf-held-hand", "heldOut", "no recording")])
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.first == "model parakeet-ultra")
    #expect(lines.contains("cuts splitter"))
    #expect(lines.contains("policy live softAfter=5 softSilence=0.4 softBoost=10"))
    #expect(lines.contains("note \(LongformSeamReplay.overCutNote)"))
    #expect(
      lines.last
        == "summary\tmeanDelta=+0.375\tseamErrors=3\tcasesWithMoreThanOneSeamError=1\t"
        + "seamErrorsPer100Words=3.000\tnearSeamWordShare=0.120")
    #expect(lines.contains("skipped\tlf-held-hand\theldOut\tno recording"))
    #expect(lines.contains("a\tread\tpieces=3\tsilent=0\tmaxPieceS=6.50\tseams=4"))
    #expect(lines.contains("c\tcomposed\tpieces=2\tsilent=1\tmaxPieceS=-\tseams=5"))
    #expect(
      lines.contains(
        "  liveOnlyErrors=2 seamErrors=1 seamErrorsPer100Words=2.500 nearSeamWordShare=0.100"))
    #expect(lines.contains("  wordAccuracy live=0.500 whole=1.000 delta=+0.500"))
  }

  @Test("words within one of a seam are the chance an error is attributed")
  func nearSeamShare() {
    #expect(LongformSeamReplay.nearSeamWordCount(liveWordCount: 6, seams: [2]) == 3)
    #expect(LongformSeamReplay.nearSeamWordCount(liveWordCount: 6, seams: [2, 3]) == 4)
    #expect(LongformSeamReplay.nearSeamWordCount(liveWordCount: 6, seams: []) == 0)
    #expect(LongformSeamReplay.nearSeamWordCount(liveWordCount: 0, seams: [0]) == 0)
    let rates = LongformSeamReplay.seamRates(seamErrors: 1, liveWords: 40, nearSeamWords: 4)
    #expect(rates.per100 == 2.5)
    #expect(rates.share == 0.1)
    #expect(LongformSeamReplay.seamRates(seamErrors: 0, liveWords: 0, nearSeamWords: 0).per100 == nil)
  }

  @Test("a pieces log maps rotations onto the wav, 0.5 s after the file starts")
  func realCutPoints() throws {
    let log = """
      2026-01-01 00:00:00.000 Df x LIVE-DICTATE: Starting (target com.apple.TextEdit)
      2026-01-01 00:00:02.000 Df x AUDIO: Rotated dictate chunk 0 at silence boundary (silent=false)
      2026-01-01 00:00:02.050 Df x LIVE-DICTATE: Silent piece skipped (a.wav)
      2026-01-01 00:00:05.000 Df x AUDIO: Rotated dictate chunk 1 at silence boundary (silent=false)
      2026-01-01 00:00:06.000 Df x LIVE-DICTATE: Silent piece skipped (tail.wav)
      2026-01-01 00:00:08.000 Df x LIVE-DICTATE: finished pieces=1 durationS=8.0
      """
    let parsed = try LongformSeamReplay.parseSessionCuts(log)
    #expect(parsed.cuts == [2.5, 5.5])
    #expect(parsed.silent == [true, false, true])
    let spans = LongformSeamReplay.pieceSpans(cuts: parsed.cuts, silent: parsed.silent, duration: 10)
    #expect(spans.map(\.start) == [0, 2.5, 5.5])
    #expect(spans.map(\.end) == [2.5, 5.5, 10])
    #expect(spans.map(\.isSilent) == [true, false, true])
  }

  @Test("a millisecond rotation lands 0.5 s plus that offset into the wav")
  func realCutLeadIn() throws {
    let log = """
      2026-11-16 13:18:18.163 Df x LIVE-DICTATE: Starting (target com.apple.TextEdit)
      2026-11-16 13:18:23.992 Df x AUDIO: Rotated dictate chunk 0 at silence boundary (silent=false)
      """
    let parsed = try LongformSeamReplay.parseSessionCuts(log)
    #expect(parsed.cuts.count == 1)
    #expect(abs(parsed.cuts[0] - 6.329) < 0.0005)
    #expect(parsed.silent == [false, false])
  }

  @Test("a missing or untimestamped starting line is a skip reason")
  func realCutRejects() {
    #expect(throws: LongformSeamReplay.CutLogError.noStartingLine) {
      try LongformSeamReplay.parseSessionCuts(
        "2026-01-01 00:00:02.000 Df x AUDIO: Rotated dictate chunk 0\n")
    }
    #expect(throws: LongformSeamReplay.CutLogError.unparseableTimestamps) {
      try LongformSeamReplay.parseSessionCuts("LIVE-DICTATE: Starting\n")
    }
  }

  @Test("policy line names the soft rule the splitter will use")
  func policyLine() {
    #expect(
      LongformSeamReplay.describe(policy: .live) == "live softAfter=5 softSilence=0.4 softBoost=10")
    #expect(LongformSeamReplay.describe(policy: .liveWithoutSoftCut) == "liveWithoutSoftCut")
    var slower = ChunkedDictateRecorder.RotationPolicy.live
    slower.softCutSilenceDuration = 0.6
    #expect(
      LongformSeamReplay.describe(policy: slower)
        == "live softAfter=5 softSilence=0.6 softBoost=10")
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
/// Each recording is transcribed once (`finishPiece`, spokenOnly) and again as pieces. `cuts`
/// `real` (the default) splits the wav at the session log's rotation times. `cuts` `splitter`
/// uses `LivePieceSplitter` and the policy in the config. Both then use the same `finishPiece` +
/// `LiveChunkJoiner` path the dictation benchmark's real tier uses.
@Suite("Long-form seam replay (opt-in)", .serialized)
struct LongformSeamReplayTests {

  struct Config: Decodable {
    let model: String
    let audioDir: String
    let corpus: String
    let cuts: String?
    let noSoft: Bool?
    let softSilence: Double?
    let softBoost: Double?
    let softAfter: Double?

    var cutMode: String { cuts ?? "real" }

    func rotationPolicy() -> ChunkedDictateRecorder.RotationPolicy {
      var policy: ChunkedDictateRecorder.RotationPolicy = noSoft == true ? .liveWithoutSoftCut : .live
      if let softSilence { policy.softCutSilenceDuration = softSilence }
      if let softBoost { policy.softCutThresholdBoostDB = Float(softBoost) }
      if let softAfter { policy.softCutAfter = softAfter }
      return policy
    }
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

    guard config.cutMode == "real" || config.cutMode == "splitter" else {
      throw ReplayFailure("unknown cuts \(config.cutMode)")
    }

    var reports: [LongformSeamReplay.CaseReport] = []
    var skipped: [(id: String, type: String, reason: String)] = []
    var seen: Set<String> = []
    for item in corpus.cases {
      seen.insert(item.id)
      let wav = audioDir.appendingPathComponent("\(item.id).wav")
      guard FileManager.default.fileExists(atPath: wav.path) else {
        skipped.append((item.id, Self.typeLabel(item), "no recording"))
        continue
      }
      print("REPLAY-PROGRESS\t\(item.id)")
      switch try Self.loadPieces(wav: wav, workDir: workDir, config: config) {
      case .skip(let reason):
        skipped.append((item.id, Self.typeLabel(item), reason))
      case .pieces(let pieces):
        reports.append(try await Self.score(
          item, wav: wav, pieces: pieces, model: model, glossary: glossary))
      }
    }
    if let names = try? FileManager.default.contentsOfDirectory(atPath: audioDir.path) {
      for name in names.filter({ $0.hasSuffix(".wav") }).sorted() {
        let id = String(name.dropLast(4))
        guard !seen.contains(id) else { continue }
        print("REPLAY-PROGRESS\t\(id)")
        let wav = audioDir.appendingPathComponent(name)
        let placeholder = CorpusFile.Case(id: id, mode: "unlisted", heldOut: false, expected: nil)
        switch try Self.loadPieces(wav: wav, workDir: workDir, config: config) {
        case .skip(let reason):
          skipped.append((id, "unlisted", reason))
        case .pieces(let pieces):
          reports.append(try await Self.score(
            placeholder, wav: wav, pieces: pieces, model: model, glossary: glossary))
        }
      }
    }

    let policy = config.cutMode == "splitter"
      ? LongformSeamReplay.describe(policy: config.rotationPolicy()) : nil
    let report = LongformSeamReplay.render(
      model: config.model, cuts: config.cutMode, policy: policy, cases: reports, skipped: skipped)
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

  private struct ReplayFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  private enum PieceSource {
    case pieces([(url: URL, isSilent: Bool, seconds: Double)])
    case skip(String)
  }

  private static func loadPieces(wav: URL, workDir: URL, config: Config) throws -> PieceSource {
    if config.cutMode == "splitter" {
      return .pieces(try LivePieceSplitter.split(wav, into: workDir, policy: config.rotationPolicy()))
    }
    let logURL = wav.deletingLastPathComponent().appendingPathComponent(
      wav.deletingPathExtension().lastPathComponent + ".pieces.log")
    guard FileManager.default.fileExists(atPath: logURL.path) else { return .skip("no pieces log") }
    let text: String
    do {
      text = try String(contentsOf: logURL, encoding: .utf8)
    } catch {
      return .skip(LongformSeamReplay.CutLogError.unparseableTimestamps.reason)
    }
    let parsed: LongformSeamReplay.SessionCuts
    do {
      parsed = try LongformSeamReplay.parseSessionCuts(text)
    } catch let error as LongformSeamReplay.CutLogError {
      return .skip(error.reason)
    }
    let file = try AVAudioFile(forReading: wav)
    let rate = file.processingFormat.sampleRate
    guard rate > 0, file.length > 0 else { return .skip("recording is empty") }
    let duration = Double(file.length) / rate
    let spans = LongformSeamReplay.pieceSpans(
      cuts: parsed.cuts, silent: parsed.silent, duration: duration)
    let samples = spans.map { span in
      (
        start: Int((span.start * rate).rounded()),
        end: Int((span.end * rate).rounded()),
        isSilent: span.isSilent)
    }
    return .pieces(try LivePieceSplitter.split(wav, into: workDir, spans: samples))
  }

  private static func score(
    _ item: CorpusFile.Case, wav: URL,
    pieces: [(url: URL, isSilent: Bool, seconds: Double)],
    model: OfflineModelType, glossary: [String]
  ) async throws -> LongformSeamReplay.CaseReport {
    try Task.checkCancellation()
    let wholeRaw = try await rawTranscript(url: wav, model: model, glossary: glossary)
    let wholeText = LiveDictation.finishPiece(wholeRaw, mode: .spokenOnly, timedMarks: true)

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
    let audible = pieces.filter { !$0.isSilent }.map(\.seconds)
    return LongformSeamReplay.CaseReport(
      id: item.id, type: typeLabel(item), pieces: pieces.count,
      silent: pieces.filter(\.isSilent).count, maxPieceSeconds: audible.max(), seams: seams,
      liveOnlyErrors: diff.liveOnlyErrors, seamErrors: diff.seamErrors, seamLines: diff.seamLines,
      liveWords: diff.liveWords, nearSeamWords: diff.nearSeamWords,
      liveAccuracy: read.map { LongformSeamReplay.wordAccuracy(output: output, expected: $0) },
      wholeAccuracy: read.map { LongformSeamReplay.wordAccuracy(output: wholeText, expected: $0) })
  }
}
