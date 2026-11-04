import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import WhisperShortcut_AppStore

// MARK: - Corpus

/// One case of `benchmarks/dictation/corpus.json`. The file's `about` field documents the schema.
struct DictationBenchmarkCase: Decodable {
  let id: String
  let tags: [String]
  let spoken: [String]
  let say: [String]?
  let expected: String
  let alternatives: [String]?
  let automatic: String?
  let automaticAlternatives: [String]?
  let terms: [String]?
  let extraGlossary: [String]?
}

struct DictationBenchmarkCorpus: Decodable {
  let about: String
  let glossary: [String]
  let cases: [DictationBenchmarkCase]
}

// MARK: - Scoring

/// Pure scoring for the dictation benchmark: no model, no audio, so it is unit-tested in
/// `DictationBenchmarkScoringTests` and can never drift from what the live run prints.
///
/// The question it answers is not "is the transcript word-perfect" but "did the dictation come out
/// the way a doctor would have typed it": spoken marks kept, no guessed marks, glossary words exact,
/// fillers gone. So marks and words are scored separately.
enum DictationBenchmarkScoring {

  static let markCharacters: Set<Character> = [",", ".", ":", ";", "/", "…", "?", "!", "\n"]

  /// The marks of `text` in order of appearance (each line break counts once).
  static func marks(_ text: String) -> [Character] {
    text.filter { markCharacters.contains($0) }
  }

  /// Lower-case words, split on whitespace, on every mark character and on `"`.
  static func words(_ text: String) -> [String] {
    text.lowercased()
      .split(whereSeparator: { $0.isWhitespace || markCharacters.contains($0) || $0 == "\"" })
      .map(String.init)
  }

  /// The candidate closest to `output` by word edit distance; ties go to the earliest.
  static func reference(output: String, candidates: [String]) -> String {
    let outputWords = words(output)
    var best = candidates[0]
    var bestDistance = Int.max
    for candidate in candidates {
      let distance = LiveDictation.editDistance(words(candidate), outputWords)
      if distance < bestDistance {
        best = candidate
        bestDistance = distance
      }
    }
    return best
  }

  static func lcsLength(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty || b.isEmpty { return 0 }
    var previous = Array(repeating: 0, count: b.count + 1)
    var current = previous
    for i in 1...a.count {
      for j in 1...b.count {
        current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }

  /// `term` occurs in `text` as a whole word, case-sensitive: no letter or digit on either side.
  static func containsWholeWord(_ text: String, term: String) -> Bool {
    guard !term.isEmpty else { return false }
    var searchRange = text.startIndex..<text.endIndex
    while let found = text.range(of: term, options: .literal, range: searchRange) {
      let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
      let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
      let boundaryBefore = before.map { !($0.isLetter || $0.isNumber) } ?? true
      let boundaryAfter = after.map { !($0.isLetter || $0.isNumber) } ?? true
      if boundaryBefore && boundaryAfter { return true }
      searchRange = found.upperBound..<text.endIndex
    }
    return false
  }

  /// What one case scored in one tier and mode.
  struct CaseResult {
    let id: String
    let tags: [String]
    let output: String
    let candidates: [String]
    /// Glossary words the output must contain / the case's whole glossary (empty when untagged).
    let terms: [String]
    let fullGlossary: [String]

    var reference: String { DictationBenchmarkScoring.reference(output: output, candidates: candidates) }
    var exact: Bool { candidates.contains(output) }
    var markLCS: Int {
      DictationBenchmarkScoring.lcsLength(
        DictationBenchmarkScoring.marks(reference), DictationBenchmarkScoring.marks(output))
    }
    var referenceMarkCount: Int { DictationBenchmarkScoring.marks(reference).count }
    var extraMarks: Int { DictationBenchmarkScoring.marks(output).count - markLCS }
    var missingMarks: Int { referenceMarkCount - markLCS }
    var wordDistance: Int {
      LiveDictation.editDistance(
        DictationBenchmarkScoring.words(reference), DictationBenchmarkScoring.words(output))
    }
    var referenceWordCount: Int { DictationBenchmarkScoring.words(reference).count }

    var glossaryOK: Bool {
      let present = { (term: String) in DictationBenchmarkScoring.containsWholeWord(output, term: term) }
      return terms.allSatisfy(present) && fullGlossary.filter { !terms.contains($0) }.allSatisfy { !present($0) }
    }
  }

  struct Metric: Equatable {
    let value: Double
    let num: Int
    let den: Int
  }

  /// Tags that occur in `results`, sorted. The table's `tag.*` rows follow the corpus.
  static func tagNames(in results: [CaseResult]) -> [String] {
    Array(Set(results.flatMap(\.tags))).sorted()
  }

  /// Metrics for one tier and mode. A metric whose denominator is 0 is omitted.
  static func metrics(_ results: [CaseResult]) -> [(name: String, metric: Metric)] {
    var out: [(String, Metric)] = []
    func add(_ name: String, _ num: Int, _ den: Int) {
      guard den > 0 else { return }
      out.append((name, Metric(value: (Double(num) / Double(den) * 1000).rounded() / 1000, num: num, den: den)))
    }
    add("exact", results.filter(\.exact).count, results.count)
    let withMarks = results.filter { $0.referenceMarkCount > 0 }
    add("spokenMarksKept", withMarks.map(\.markLCS).reduce(0, +), withMarks.map(\.referenceMarkCount).reduce(0, +))
    add("noGuessedMarks", results.filter { $0.extraMarks == 0 }.count, results.count)
    let glossaryCases = results.filter { $0.tags.contains("glossary") }
    add("glossary", glossaryCases.filter(\.glossaryOK).count, glossaryCases.count)
    let totalWords = results.map(\.referenceWordCount).reduce(0, +)
    add("wordAccuracy", totalWords - results.map(\.wordDistance).reduce(0, +), totalWords)
    for tag in tagNames(in: results) {
      let tagged = results.filter { $0.tags.contains(tag) }
      add("tag.\(tag)", tagged.filter(\.exact).count, tagged.count)
    }
    return out.map { (name: $0.0, metric: $0.1) }
  }
}

// MARK: - Live pieces

/// Cuts a recording into pieces the way Dictate Live does (`ChunkedDictateRecorder.RotationPolicy.live`):
/// a piece is at least 1.5 s long and is cut after 0.6 s below −45 dB, which is three evaluations
/// spaced 0.2 s apart. Windows are counted from the start of the recording, like the recorder's
/// `meteringTickCount`, and a piece whose loudest window stays below −45 dB is silent.
///
/// It approximates the recorder's live metering offline (RMS of a 50 ms window vs
/// AVAudioRecorder's averagePower), so a pause near the 0.6 s / −45 dB edge may cut differently
/// than the app.
enum LivePieceSplitter {
  private static let windowSeconds = 0.05
  private static let minPieceSeconds = 1.5
  private static let silenceThresholdDB: Float = -45
  private static let evaluationStride = 4
  private static let silentEvaluationsToCut = 3
  private static let outputSampleRate = 16_000.0

  private struct SplitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// Pieces in order. A recording with no cut returns the original URL as its one piece.
  static func split(_ url: URL, into dir: URL) throws -> [(url: URL, isSilent: Bool)] {
    let (samples, sampleRate) = try readMono(url)
    guard !samples.isEmpty, sampleRate > 0 else { return [(url: url, isSilent: true)] }

    let window = max(1, Int((windowSeconds * sampleRate).rounded()))
    let minSamples = Int((minPieceSeconds * sampleRate).rounded())
    var ranges: [(start: Int, end: Int, peak: Float)] = []
    var pieceStart = 0
    var peak = -Float.infinity
    var silentCount = 0
    var windowNumber = 0
    var offset = 0
    while offset < samples.count {
      let end = min(offset + window, samples.count)
      windowNumber += 1
      let power = windowPower(samples[offset..<end])
      peak = max(peak, power)
      if windowNumber % evaluationStride == 0, end - pieceStart >= minSamples {
        if power < silenceThresholdDB {
          silentCount += 1
          if silentCount >= silentEvaluationsToCut {
            ranges.append((start: pieceStart, end: end, peak: peak))
            pieceStart = end
            peak = -Float.infinity
            silentCount = 0
          }
        } else {
          silentCount = 0
        }
      }
      offset = end
    }
    if pieceStart < samples.count {
      ranges.append((start: pieceStart, end: samples.count, peak: peak))
    }
    if ranges.isEmpty { return [(url: url, isSilent: true)] }
    if ranges.count == 1, ranges[0].start == 0, ranges[0].end == samples.count {
      return [(url: url, isSilent: ranges[0].peak < silenceThresholdDB)]
    }

    let base = url.deletingPathExtension().lastPathComponent
    var pieces: [(url: URL, isSilent: Bool)] = []
    pieces.reserveCapacity(ranges.count)
    for (index, range) in ranges.enumerated() {
      let pieceURL = dir.appendingPathComponent("\(base)-live\(index + 1).wav")
      try writeWAV(Array(samples[range.start..<range.end]), sampleRate: sampleRate, to: pieceURL)
      pieces.append((url: pieceURL, isSilent: range.peak < silenceThresholdDB))
    }
    return pieces
  }

  private static func windowPower(_ samples: ArraySlice<Float>) -> Float {
    var sum: Float = 0
    for sample in samples { sum += sample * sample }
    let rms = sqrt(sum / Float(samples.count))
    return Float(20) * log10(max(rms, Float(1e-9)))
  }

  private static func readMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let capacity = AVAudioFrameCount(file.length)
    guard capacity > 0 else { return ([], format.sampleRate) }
    guard
      format.channelCount >= 1,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
    else {
      throw SplitError(message: "could not read \(url.lastPathComponent)")
    }
    try file.read(into: buffer)
    let count = Int(buffer.frameLength)
    guard count > 0, let channels = buffer.floatChannelData else {
      throw SplitError(message: "\(url.lastPathComponent) is not float PCM")
    }
    let channelCount = Int(format.channelCount)
    var samples = [Float](repeating: 0, count: count)
    if channelCount == 1 {
      samples.withUnsafeMutableBufferPointer { destination in
        destination.baseAddress?.update(from: channels[0], count: count)
      }
    } else {
      for index in 0..<count {
        var sum: Float = 0
        for channel in 0..<channelCount { sum += channels[channel][index] }
        samples[index] = sum / Float(channelCount)
      }
    }
    return (samples, format.sampleRate)
  }

  private static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
    guard !samples.isEmpty,
      let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
      let sourceBuffer = AVAudioPCMBuffer(
        pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
      let sourceChannels = sourceBuffer.floatChannelData
    else {
      throw SplitError(message: "could not build a buffer for \(url.lastPathComponent)")
    }
    sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      if let base = source.baseAddress {
        sourceChannels[0].update(from: base, count: samples.count)
      }
    }

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: outputSampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    let output = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    if abs(sampleRate - outputSampleRate) < 0.5 {
      try output.write(from: sourceBuffer)
      output.close()
      return
    }

    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
    else {
      throw SplitError(message: "no converter to 16 kHz for \(url.lastPathComponent)")
    }
    let outFrames = AVAudioFrameCount(
      (Double(samples.count) * outputSampleRate / sampleRate).rounded(.up)) + 256
    guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrames) else {
      throw SplitError(message: "could not allocate a 16 kHz buffer for \(url.lastPathComponent)")
    }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: converted, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .endOfStream
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return sourceBuffer
    }
    if let error { throw error }
    guard status != .error, converted.frameLength > 0 else {
      throw SplitError(message: "resample failed for \(url.lastPathComponent)")
    }
    try output.write(from: converted)
    output.close()
  }
}

// MARK: - Hermetic suite

/// Always runs, no model and no audio: the metric definitions and the corpus file itself.
@Suite("Dictation benchmark scoring")
struct DictationBenchmarkScoringTests {

  typealias Scoring = DictationBenchmarkScoring

  static func loadCorpus() throws -> (corpus: DictationBenchmarkCorpus, data: Data) {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("benchmarks/dictation/corpus.json")
    let data = try Data(contentsOf: url)
    return (try JSONDecoder().decode(DictationBenchmarkCorpus.self, from: data), data)
  }

  private func result(
    _ output: String, _ candidates: [String], tags: [String] = [], terms: [String] = [],
    glossary: [String] = []
  ) -> Scoring.CaseResult {
    Scoring.CaseResult(
      id: "t", tags: tags, output: output, candidates: candidates, terms: terms, fullGlossary: glossary)
  }

  @Test("marks are the mark characters in order, newlines once each")
  func marks() {
    #expect(Scoring.marks("Gesamt GdB 50, Merkzeichen G.") == [",", "."])
    #expect(Scoring.marks("a/b… c\nd: e; f? g!") == ["/", "…", "\n", ":", ";", "?", "!"])
    #expect(Scoring.marks("keine Zeichen").isEmpty)
  }

  @Test("words lower-case and split on whitespace, marks and quotes")
  func words() {
    #expect(Scoring.words("Arbeitsmarkt/im ADL eingeschränkt.") == ["arbeitsmarkt", "im", "adl", "eingeschränkt"])
    #expect(Scoring.words("Er sagte \"Ja\", dann… ging.") == ["er", "sagte", "ja", "dann", "ging"])
    #expect(Scoring.words(" , . ").isEmpty)
  }

  @Test("reference picks the closest candidate, the earliest on a tie")
  func reference() {
    #expect(Scoring.reference(output: "um zehn uhr", candidates: ["Um 10 Uhr", "Um zehn Uhr"]) == "Um zehn Uhr")
    #expect(Scoring.reference(output: "ganz anders", candidates: ["Eins zwei", "Drei vier"]) == "Eins zwei")
  }

  @Test("exact needs the whole string to equal a candidate")
  func exact() {
    #expect(result("Um zehn Uhr", ["Um 10 Uhr", "Um zehn Uhr"]).exact)
    #expect(!result("Um zehn Uhr.", ["Um 10 Uhr", "Um zehn Uhr"]).exact)
  }

  @Test("mark LCS, extra and missing marks")
  func markCounts() {
    let kept = result("Gangbild, geht weiter.", ["Gangbild, geht weiter."])
    #expect(kept.markLCS == 2 && kept.extraMarks == 0 && kept.missingMarks == 0)
    let guessed = result("Gangbild, geht, weiter.", ["Gangbild, geht weiter."])
    #expect(guessed.markLCS == 2 && guessed.extraMarks == 1 && guessed.missingMarks == 0)
    let lost = result("Gangbild geht weiter", ["Gangbild, geht weiter."])
    #expect(lost.markLCS == 0 && lost.extraMarks == 0 && lost.missingMarks == 2)
    let swapped = result("Gangbild. geht weiter,", ["Gangbild, geht weiter."])
    #expect(swapped.markLCS == 1 && swapped.extraMarks == 1 && swapped.missingMarks == 1)
  }

  @Test("glossary needs every term as a whole word and none of the other glossary words")
  func glossary() {
    let full = ["GdB", "ADL", "Kizomba"]
    #expect(result("Gesamt GdB 50.", ["x"], terms: ["GdB"], glossary: full).glossaryOK)
    #expect(!result("Gesamt gdb 50.", ["x"], terms: ["GdB"], glossary: full).glossaryOK)
    #expect(!result("Gesamt GdBs 50.", ["x"], terms: ["GdB"], glossary: full).glossaryOK)
    #expect(!result("Gesamt GdB und ADL.", ["x"], terms: ["GdB"], glossary: full).glossaryOK)
    #expect(result("Gangbild, geht weiter.", ["x"], terms: [], glossary: full).glossaryOK)
    #expect(!result("Gangbild Kizomba.", ["x"], terms: [], glossary: full).glossaryOK)
    #expect(result("Im ADL/GdB-Bereich", ["x"], terms: ["ADL", "GdB"], glossary: full).glossaryOK)
  }

  @Test("metrics: values, num/den, omitted when the denominator is 0")
  func metrics() {
    let results = [
      result("Gangbild, geht weiter.", ["Gangbild, geht weiter."], tags: ["spokenMarks"]),
      result("Hüfte, rechts Knie", ["Hüfte rechts, Knie"], tags: ["spokenMarks"]),
      result("Befund unauffällig", ["Befund unauffällig"], tags: ["noMarks"]),
    ]
    let byName = Dictionary(uniqueKeysWithValues: Scoring.metrics(results).map { ($0.name, $0.metric) })
    #expect(byName["exact"] == .init(value: 0.667, num: 2, den: 3))
    // case 2: ref marks [","], output marks [","] → LCS 1; total ref marks 2 + 1 = 3, kept 2 + 1.
    #expect(byName["spokenMarksKept"] == .init(value: 1.0, num: 3, den: 3))
    #expect(byName["noGuessedMarks"] == .init(value: 1.0, num: 3, den: 3))
    #expect(byName["tag.spokenMarks"] == .init(value: 0.5, num: 1, den: 2))
    #expect(byName["tag.noMarks"] == .init(value: 1.0, num: 1, den: 1))
    // words: ref 3 + 3 + 2 = 8; case 2 differs by 2 substitutions/moves.
    #expect(byName["wordAccuracy"]?.den == 8)
    #expect(byName["glossary"] == nil)
    #expect(byName["tag.fillers"] == nil)
  }

  @Test("corpus.json decodes, ids are unique, spoken is filled, say matches spoken")
  func corpusIsWellFormed() throws {
    let (corpus, _) = try Self.loadCorpus()
    #expect(!corpus.cases.isEmpty)
    #expect(Set(corpus.cases.map(\.id)).count == corpus.cases.count)
    for item in corpus.cases {
      #expect(!item.spoken.isEmpty, "\(item.id): spoken is empty")
      #expect(item.spoken.allSatisfy { !$0.isEmpty }, "\(item.id): empty dictation")
      if let say = item.say {
        #expect(say.count == item.spoken.count, "\(item.id): say and spoken differ in count")
      }
      #expect(!item.tags.isEmpty, "\(item.id): no tags")
    }
    let scored = corpus.cases.map { item in
      result(item.expected, [item.expected], tags: item.tags)
    }
    let metricNames = Set(Scoring.metrics(scored).map(\.name))
    let tags = Set(corpus.cases.flatMap(\.tags))
    #expect(tags.contains("pause"))
    #expect(metricNames.isSuperset(of: Set(tags.map { "tag.\($0)" })))
  }

  /// 440 Hz at −10 dBFS, digital silence, then the tone again. Durations are seconds at 16 kHz.
  private func toneSilenceTone(_ head: Double, _ silence: Double, _ tail: Double) -> [Float] {
    let rate = 16_000.0
    let amplitude = Float(pow(10.0, -10.0 / 20.0) * sqrt(2.0))
    func tone(_ duration: Double) -> [Float] {
      (0..<Int(duration * rate)).map { i in
        amplitude * sin(2 * Float.pi * 440 * Float(i) / Float(rate))
      }
    }
    func zeros(_ duration: Double) -> [Float] {
      Array(repeating: Float(0), count: Int(duration * rate))
    }
    return tone(head) + zeros(silence) + tone(tail)
  }

  private func writeWAV(_ samples: [Float], to url: URL) throws {
    let sampleRate = 16_000.0
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData
    else {
      throw NSError(domain: "DictationBenchmarkScoringTests", code: 1)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (index, sample) in samples.enumerated() { channel[0][index] = sample }
    try file.write(from: buffer)
    file.close()
  }

  private func splitFixture(
    _ samples: [Float],
    _ check: (URL, [(url: URL, isSilent: Bool)]) throws -> Void
  ) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("live-piece-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = dir.appendingPathComponent("source.wav")
    try writeWAV(samples, to: source)
    try check(source, LivePieceSplitter.split(source, into: dir))
  }

  private func frames(_ url: URL) throws -> Int {
    Int(try AVAudioFile(forReading: url).length)
  }

  @Test("2s tone, 1s silence, 2s tone cuts into two non-silent pieces")
  func splitLongPause() throws {
    try splitFixture(toneSilenceTone(2, 1, 2)) { source, pieces in
      #expect(pieces.map(\.isSilent) == [false, false])
      #expect(pieces.allSatisfy { $0.url != source })
      // Silence counting starts at 1.6 s; the silent checks at 2.2, 2.4 and 2.6 s cut there.
      let head = try frames(pieces[0].url)
      let tail = try frames(pieces[1].url)
      #expect(head == 41_600)
      #expect(tail == 38_400)
      let format = try AVAudioFile(forReading: pieces[0].url).fileFormat
      #expect(format.sampleRate == 16_000)
      #expect(format.channelCount == 1)
      #expect(format.commonFormat == .pcmFormatInt16)
    }
  }

  @Test("2s tone, 0.4s silence, 2s tone stays one piece")
  func splitShortPause() throws {
    try splitFixture(toneSilenceTone(2, 0.4, 2)) { source, pieces in
      #expect(pieces.count == 1)
      #expect(pieces[0].isSilent == false)
      #expect(pieces[0].url == source)
    }
  }

  @Test(
    "1s tone, 1s silence, 1s tone cuts at 2.0s: the 1.5s minimum delays counting until 1.6s, then 1.6, 1.8 and 2.0s are the three silent checks"
  )
  func splitMinimumDurationStillCutsAtEndOfSilence() throws {
    // The cut cannot happen before the piece is 1.5 s. Counting therefore starts at the 1.6 s
    // check, inside the silence, and the checks at 1.6, 1.8 and 2.0 s are all silent, so the
    // piece ends at 2.0 s. The last second of tone is a second non-silent piece.
    try splitFixture(toneSilenceTone(1, 1, 1)) { _, pieces in
      #expect(pieces.map(\.isSilent) == [false, false])
      let head = try frames(pieces[0].url)
      let tail = try frames(pieces[1].url)
      #expect(head == 32_000)
      #expect(tail == 16_000)
    }
  }

  @Test("2s of digital silence is one silent piece")
  func splitAllSilence() throws {
    try splitFixture(Array(repeating: Float(0), count: 32_000)) { source, pieces in
      #expect(pieces.count == 1)
      #expect(pieces[0].isSilent == true)
      #expect(pieces[0].url == source)
    }
  }
}

// MARK: - Live benchmark

/// Scores one speech model plus the app's post-processing on the fixed German dictation corpus in
/// `benchmarks/dictation/`, per audio tier (`say` voices, real recordings) and punctuation mode.
/// Replaces the pass/fail pilot that used to live in `LiveDictationPilotTests`.
///
/// Run it with `scripts/dictation-benchmark.sh`, not by hand. It is enabled by a config file
/// instead of an environment variable: neither a shell export nor `TEST_RUNNER_` reaches this
/// sandboxed test host (see `OfflineWhisperBenchmarkTests`), but the test can read repo files by
/// `#filePath`. The script writes `build/dictation-benchmark/config.json`; the test runs only
/// while that file exists and is younger than six hours, so a leftover file never turns a model
/// download and minutes of decoding on in `run-tests.sh`.
///
/// Decoding follows the app: each dictation is cut into live pieces offline (`LivePieceSplitter`),
/// silent pieces are skipped, and the rest are decoded one by one. Glossary = corpus glossary +
/// the case's `extraGlossary`, Parakeet gets it as `vocabulary`, Whisper as `prompt`; `finishPiece`
/// with `timedMarks: true` as `MenuBarController.decodeLivePiece` does. Pieces of one dictation
/// share one `LiveChunkJoiner`, seeded with the previous character; dictations of one case are
/// joined like back-to-back live dictations.
///
/// Gate: a metric below the committed `baseline.json` fails the test. Nothing is gated for a tier
/// when the corpus or that tier's audio changed, when it has missing recordings, or when the
/// baseline is being rewritten — a comparison across different inputs says nothing.
@Suite("Dictation benchmark (opt-in)", .serialized)
struct DictationBenchmarkTests {

  struct Config: Decodable {
    struct Tier: Decodable {
      let name: String
      let kind: String
      let voice: String?
      let dir: String?
    }
    let model: String
    let tiers: [Tier]
    let updateBaseline: Bool
  }

  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
  private static let configURL = repoRoot.appendingPathComponent("build/dictation-benchmark/config.json")

  private static var configIsFresh: Bool {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path),
      let modified = attributes[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(modified) < 6 * 3600
  }

  private static func sha256Prefix(_ data: Data) -> String {
    String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
  }

  private static func say(_ text: String, voice: String, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "DictationBenchmarkTests", code: Int(process.terminationStatus))
    }
  }

  private static func oneLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "⏎")
  }

  private static func format(_ value: Double?) -> String {
    value.map { String(format: "%.3f", $0) } ?? "-"
  }

  /// The audio fingerprint of a real-recording tier: names and bytes of its sorted `.wav` files.
  private static func wavFingerprint(dir: URL) -> String {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
      .filter { $0.hasSuffix(".wav") }.sorted()
    var hasher = SHA256()
    for name in names {
      hasher.update(data: Data(name.utf8))
      if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) { hasher.update(data: data) }
    }
    return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
  }

  @Test(
    "Dictation corpus, TTS and real recordings to final text",
    .enabled(if: configIsFresh, "Run scripts/dictation-benchmark.sh to enable"))
  func benchmark() async throws {
    setvbuf(stdout, nil, _IONBF, 0)
    let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: Self.configURL))
    let corpusData = try Data(
      contentsOf: Self.repoRoot.appendingPathComponent("benchmarks/dictation/corpus.json"))
    let corpus = try JSONDecoder().decode(DictationBenchmarkCorpus.self, from: corpusData)
    let corpusHash = Self.sha256Prefix(corpusData)
    let baselineURL = Self.repoRoot.appendingPathComponent("benchmarks/dictation/baseline.json")
    let baselineRoot =
      (try? Data(contentsOf: baselineURL))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let baselineModel = baselineRoot[config.model] as? [String: Any]
    let baselineTiers = baselineModel?["tiers"] as? [String: Any] ?? [:]
    let baselineCorpusHash = baselineModel?["corpusHash"] as? String

    let model = try #require(OfflineModelType(rawValue: config.model), "unknown model \(config.model)")
    try await ModelManager.shared.ensureReady(model)
    try await LocalSpeechService.shared.initializeModel(model)

    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dictation-benchmark-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    var jsonTiers: [String: Any] = [:]
    print(
      "BENCH-NOTE\trun\tdictations are cut into live pieces offline (≥1.5 s, 0.6 s below −45 dB)")

    for tier in config.tiers {
      var missing: [String] = []
      // [mode: [CaseResult]]
      var results: [PunctuationMode: [DictationBenchmarkScoring.CaseResult]] = [:]
      var rawByCase: [String: [PunctuationMode: String]] = [:]
      var pieceCountsByCase: [String: String] = [:]

      for item in corpus.cases {
        // Audio per dictation; one absent file makes the whole case MISSING in this tier.
        var audio: [URL] = []
        for (index, spoken) in item.spoken.enumerated() {
          if tier.kind == "say" {
            let url = workDir.appendingPathComponent("\(tier.name)-\(item.id)-\(index + 1).wav")
            try Self.say(item.say?[index] ?? spoken, voice: tier.voice ?? "Anna", to: url)
            audio.append(url)
          } else if let dir = tier.dir {
            let name = item.spoken.count == 1 ? "\(item.id).wav" : "\(item.id)-\(index + 1).wav"
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { audio.append(url) }
          }
        }
        guard audio.count == item.spoken.count else {
          missing.append(item.id)
          continue
        }

        let glossary = corpus.glossary + (item.extraGlossary ?? [])
        let splits = try audio.map { try LivePieceSplitter.split($0, into: workDir) }
        pieceCountsByCase[item.id] = splits.map { String($0.count) }.joined(separator: ",")
        for mode in [PunctuationMode.spokenOnly, .automatic] {
          if mode == .automatic && item.automatic == nil { continue }
          var output = ""
          var rawPieces: [String] = []
          for split in splits {
            var joiner = LiveChunkJoiner()
            joiner.holdsPeriods = mode != .spokenOnly
            joiner.seed(output.last.map { .character($0) } ?? .unknown)
            for piece in split where !piece.isSilent {
              var raw: String
              do {
                if model.engine == .parakeet {
                  raw = try await LocalSpeechService.shared.transcribe(
                    audioURL: piece.url, language: "de", vocabulary: glossary,
                    spokenMarksOnly: mode == .spokenOnly)
                } else {
                  raw = try await LocalSpeechService.shared.transcribe(
                    audioURL: piece.url, language: "de", prompt: glossary.joined(separator: ", "),
                    vocabulary: [], spokenMarksOnly: mode == .spokenOnly)
                }
              } catch TranscriptionError.noSpeechDetected {
                raw = ""
              }
              rawPieces.append(raw)
              output += joiner.next(LiveDictation.finishPiece(raw, mode: mode, timedMarks: true))
            }
            output += joiner.finish()
          }
          let candidates =
            mode == .spokenOnly
            ? [item.expected] + (item.alternatives ?? [])
            : [item.automatic!] + (item.automaticAlternatives ?? [])
          let isGlossary = item.tags.contains("glossary")
          results[mode, default: []].append(
            DictationBenchmarkScoring.CaseResult(
              id: item.id, tags: item.tags, output: output, candidates: candidates,
              terms: isGlossary ? (item.terms ?? []) : [],
              fullGlossary: isGlossary ? glossary : []))
          rawByCase[item.id, default: [:]][mode] = rawPieces.joined(separator: " | ")
        }
      }

      // Per-case lines.
      for mode in [PunctuationMode.spokenOnly, .automatic] {
        for item in corpus.cases {
          if missing.contains(item.id) {
            if mode == .spokenOnly || item.automatic != nil {
              print("BENCH-CASE\t\(tier.name)\t\(mode.rawValue)\t\(item.id)\tMISSING\t-\t-\t-")
            }
            continue
          }
          guard let result = results[mode]?.first(where: { $0.id == item.id }) else { continue }
          print(
            "BENCH-CASE\t\(tier.name)\t\(mode.rawValue)\t\(item.id)\t\(result.exact ? "PASS" : "FAIL")\t"
              + "\(Self.oneLine(result.output))\t\(Self.oneLine(result.candidates[0]))\t"
              + "\(Self.oneLine(rawByCase[item.id]?[mode] ?? ""))\t"
              + "pieces=\(pieceCountsByCase[item.id] ?? "")")
        }
      }

      // Fingerprint and gating decision for this tier.
      let fingerprint =
        tier.kind == "say"
        ? "say:\(tier.voice ?? ""):\(ProcessInfo.processInfo.operatingSystemVersionString)"
        : Self.wavFingerprint(dir: URL(fileURLWithPath: tier.dir ?? ""))
      let baselineTier = baselineTiers[tier.name] as? [String: Any]
      var ungatedReason: String?
      if config.updateBaseline {
        ungatedReason = "updating the baseline"
      } else if baselineTier == nil {
        ungatedReason = "no baseline for \(config.model)/\(tier.name) — run with --update-baseline"
      } else if baselineCorpusHash != corpusHash {
        ungatedReason = "corpus changed — run with --update-baseline"
      } else if baselineTier?["audioFingerprint"] as? String != fingerprint {
        ungatedReason = "audio changed (\(fingerprint)) — run with --update-baseline"
      } else if !missing.isEmpty {
        ungatedReason = "missing recordings: \(missing.joined(separator: ", "))"
      }
      if let ungatedReason { print("BENCH-NOTE\t\(tier.name)\tnot gated: \(ungatedReason)") }

      var tierJSON: [String: Any] = ["audioFingerprint": fingerprint, "missing": missing]
      for mode in [PunctuationMode.spokenOnly, .automatic] {
        let metrics = DictationBenchmarkScoring.metrics(results[mode] ?? [])
        let baselineMode = baselineTier?[mode.rawValue] as? [String: Double] ?? [:]
        var values: [String: Double] = [:]
        for (name, metric) in metrics {
          values[name] = metric.value
          let baselineValue = baselineMode[name]
          var delta = "-"
          var status = "NEW"
          if ungatedReason != nil {
            status = "UNGATED"
            if let baselineValue { delta = String(format: "%+.3f", metric.value - baselineValue) }
          } else if let baselineValue {
            delta = String(format: "%+.3f", metric.value - baselineValue)
            if metric.value < baselineValue - 0.0005 {
              status = "REGRESSION"
              Issue.record(
                "\(tier.name) \(mode.rawValue) \(name) \(metric.value) < baseline \(baselineValue)")
            } else {
              status = "OK"
            }
          }
          print(
            "BENCH-SCORE\t\(tier.name)\t\(mode.rawValue)\t\(name)\t\(Self.format(metric.value))\t"
              + "\(metric.num)/\(metric.den)\t\(Self.format(baselineValue))\t\(delta)\t\(status)")
        }
        tierJSON[mode.rawValue] = values
      }
      jsonTiers[tier.name] = tierJSON
    }

    let summary: [String: Any] = ["model": config.model, "corpusHash": corpusHash, "tiers": jsonTiers]
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
    print("BENCH-JSON " + String(decoding: data, as: UTF8.self))
  }
}
