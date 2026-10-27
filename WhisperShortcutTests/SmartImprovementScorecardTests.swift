import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Smart Improvement scorecard")
struct SmartImprovementScorecardTests {

  @Test("Rejected spellings are parsed, deduped, and lines without an annotation are ignored")
  func rejectedSpellingsParseAnnotations() {
    let first = #"""
    bachata (not "Butcher")
    Claude CLI (not "Cloud CLI")
    plain term without annotation
    """#
    let second = #"""
    Gödde (nicht "Godde, Goedde")
    other (not "butcher")
    """#
    #expect(SmartImprovementScorecard.rejectedSpellings(in: [first, second]) == [
      "Butcher", "Cloud CLI", "Godde", "Goedde",
    ])
  }

  @Test("Rejected-spelling hits are whole words, case- and diacritic-insensitive, and skip compounds")
  func rejectedSpellingHitsCountWholeWords() {
    #expect(SmartImprovementScorecard.rejectedSpellingHits(in: "ich tanze Butcher", rejected: ["Butcher"]) == 1)
    #expect(SmartImprovementScorecard.rejectedSpellingHits(in: "ich tanze butcher", rejected: ["Butcher"]) == 1)
    #expect(SmartImprovementScorecard.rejectedSpellingHits(in: "ich tanze Butchers", rejected: ["Butcher"]) == 0)
    #expect(SmartImprovementScorecard.rejectedSpellingHits(in: "Google Cloud", rejected: ["Cloud"]) == 0)
    #expect(SmartImprovementScorecard.rejectedSpellingHits(in: "die Cloud", rejected: ["Cloud"]) == 1)
    #expect(
      SmartImprovementScorecard.rejectedSpellingHits(
        in: "die Cloud CLI", rejected: ["Cloud", "Cloud CLI"]) == 1)
    #expect(SmartImprovementScorecard.rejectedSpellingHits(in: "goedde", rejected: ["Goedde"]) == 1)
  }

  @Test("Rejected-spelling hits per 100 transcriptions")
  func spellingHitRate() {
    let interactions = [
      interaction(ts: "2026-10-19T05:28:33.481Z", mode: "transcription", result: "ich tanze Butcher"),
      interaction(ts: "2026-10-19T06:00:00Z", mode: "transcription", result: "hello"),
      interaction(ts: "2026-10-19T07:00:00Z", mode: "transcription", result: "noch ein Butcher"),
      interaction(ts: "2026-10-19T08:00:00Z", mode: "transcription", result: "world"),
    ]
    let metrics = SmartImprovementScorecard.metrics(
      interactions: interactions, signals: [], rejected: ["Butcher"],
      from: .distantPast, to: .distantFuture)
    #expect(metrics.transcriptions == 4)
    #expect(metrics.rejectedSpellingHits == 2)
    #expect(metrics.rejectedSpellingHitsPer100 == 50)
  }

  @Test("A prompt is a follow-up only of the previous prompt, inside the window, when the text matches")
  func followUpRate() throws {
    let response = "Hallo Martin, danke für die Nachricht."
    let interactions = [
      interaction(ts: "2026-10-19T10:00:00Z", mode: "prompt", modelResponse: response),
      interaction(
        ts: "2026-10-19T10:01:00Z", mode: "prompt",
        selectedText: "Hallo Martin, danke für die Nachricht",
        modelResponse: "Gern geschehen."),
      interaction(
        ts: "2026-10-19T10:11:00Z", mode: "prompt",
        selectedText: "Gern geschehen.",
        modelResponse: "Gern geschehen."),
      interaction(
        ts: "2026-10-19T10:11:30Z", mode: "prompt",
        selectedText: "xyz qqq",
        modelResponse: "something else"),
    ]
    let metrics = SmartImprovementScorecard.metrics(
      interactions: interactions, signals: [], rejected: [],
      from: .distantPast, to: .distantFuture)
    #expect(metrics.prompts == 4)
    #expect(metrics.promptFollowUps == 1)
    #expect(metrics.followUpRate == 25)

    let fromB = try #require(ISO8601DateFormatter().date(from: "2026-10-19T10:01:00Z"))
    let windowed = SmartImprovementScorecard.metrics(
      interactions: interactions, signals: [], rejected: [],
      from: fromB, to: .distantFuture)
    #expect(windowed.prompts == 3)
    #expect(windowed.promptFollowUps == 1)
  }

  /// 7 of the previous output's 10 words. Jaccard is 0.7, over `PromptFollowUp`'s 0.6, so the
  /// logged signal counts it. Word-Levenshtein is also 0.7, under the scorecard's old 0.8
  /// cutoff, which is why this pair used to be missed. `followUpRate` above is unchanged:
  /// its pairs are a near-copy (both rules agree) and an out-of-window prompt.
  @Test("A shortened selection of the previous output counts, matching the logged signal")
  func followUpMatchesTheLoggedSignal() {
    let response = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
    let shortened = "alpha beta gamma delta epsilon zeta eta"
    let interactions = [
      interaction(ts: "2026-10-19T10:00:00Z", mode: "prompt", modelResponse: response),
      interaction(
        ts: "2026-10-19T10:01:00Z", mode: "prompt",
        selectedText: shortened, modelResponse: "ok"),
    ]
    let metrics = SmartImprovementScorecard.metrics(
      interactions: interactions, signals: [], rejected: [],
      from: .distantPast, to: .distantFuture)
    #expect(metrics.prompts == 2)
    #expect(metrics.promptFollowUps == 1)
    #expect(PromptFollowUp.isFollowUp(selection: shortened, previousResponse: response, gap: 60))
  }

  @Test("Dashes inserted only from a dash-free, non-empty selection")
  func dashInsertion() {
    let interactions = [
      interaction(
        ts: "2026-10-19T10:00:00Z", mode: "prompt",
        selectedText: "hello there", modelResponse: "hello \u{2014} there"),
      interaction(
        ts: "2026-10-19T10:01:00Z", mode: "prompt",
        selectedText: "range 1\u{2013}10", modelResponse: "range 1\u{2013}10"),
      interaction(
        ts: "2026-10-19T10:02:00Z", mode: "prompt",
        selectedText: "   ", modelResponse: "\u{2014}"),
      interaction(
        ts: "2026-10-19T10:03:00Z", mode: "prompt",
        selectedText: "keep this", modelResponse: "keep - this"),
    ]
    let metrics = SmartImprovementScorecard.metrics(
      interactions: interactions, signals: [], rejected: [],
      from: .distantPast, to: .distantFuture)
    #expect(metrics.dashFreeSelections == 2)
    #expect(metrics.dashesInserted == 1)
  }

  @Test("Retry rates use prompts and chat turns as the denominators")
  func retryRates() {
    let interactions = [
      interaction(ts: "2026-10-19T10:00:00Z", mode: "prompt"),
      interaction(ts: "2026-10-19T10:01:00Z", mode: "prompt"),
      interaction(ts: "2026-10-19T10:02:00Z", mode: "prompt"),
      interaction(ts: "2026-10-19T10:03:00Z", mode: "prompt"),
      interaction(ts: "2026-10-19T10:04:00Z", mode: "geminiChat"),
      interaction(ts: "2026-10-19T10:05:00Z", mode: "geminiChat"),
    ]
    let signals = [
      signal(ts: "2026-10-19T10:06:00Z", kind: "promptRetry"),
      signal(ts: "2026-10-19T10:07:00Z", kind: "promptRetry"),
      signal(ts: "2026-10-19T10:08:00Z", kind: "chatRetry"),
    ]
    let metrics = SmartImprovementScorecard.metrics(
      interactions: interactions, signals: signals, rejected: [],
      from: .distantPast, to: .distantFuture)
    #expect(metrics.promptRetriesPer100 == 50)
    #expect(metrics.chatRetriesPer100 == 50)
  }

  @Test("Sunday and the following Monday land in consecutive ISO weeks")
  func isoWeeks() {
    var utc = Calendar(identifier: .iso8601)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    utc.firstWeekday = 2
    utc.minimumDaysInFirstWeek = 4
    let interactions = [
      interaction(ts: "2026-10-18T12:00:00Z", mode: "transcription", result: "sunday"),
      interaction(ts: "2026-10-19T12:00:00Z", mode: "transcription", result: "monday"),
    ]
    let weeks = SmartImprovementScorecard.weeks(
      interactions: interactions, signals: [], rejected: [], calendar: utc)
    #expect(weeks.map(\.id) == ["2026-W42", "2026-W43"])
    let monday = utc.date(from: DateComponents(
      timeZone: utc.timeZone, year: 2026, month: 10, day: 19))
    #expect(weeks.last?.start == monday)
  }

  @Test("History lines without a scorecard still decode, and a scorecard round-trips")
  func historyScorecardBackwardCompatible() throws {
    let old = """
    {"ts":"2026-09-01T00:00:00Z","section":"dictation","source":"auto","previousLength":3,"newLength":4,"content":"hello","model":"Gemini 3.1 Pro"}
    """
    let decoded = try JSONDecoder().decode(UnifiedSystemPromptHistoryEntry.self, from: Data(old.utf8))
    #expect(decoded.scorecard == nil)
    #expect(decoded.section == "dictation")
    #expect(decoded.content == "hello")

    let metrics = ScorecardMetrics(transcriptions: 4, prompts: 2, chatTurns: 1)
    let entry = UnifiedSystemPromptHistoryEntry(
      ts: "2026-10-19T06:00:00Z",
      section: "whisperGlossary",
      source: "auto",
      previousLength: 1,
      newLength: 2,
      content: #"bachata (not "Butcher")"#,
      model: nil,
      scorecard: metrics)
    let data = try JSONEncoder().encode(entry)
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("followUpRate"))
    #expect(!json.contains("isEmpty"))
    let roundTrip = try JSONDecoder().decode(UnifiedSystemPromptHistoryEntry.self, from: data)
    #expect(roundTrip.ts == entry.ts)
    #expect(roundTrip.section == entry.section)
    #expect(roundTrip.source == entry.source)
    #expect(roundTrip.previousLength == entry.previousLength)
    #expect(roundTrip.newLength == entry.newLength)
    #expect(roundTrip.content == entry.content)
    #expect(roundTrip.model == nil)
    #expect(roundTrip.scorecard == metrics)

    let partial = """
    {"ts":"2026-10-02T00:00:00Z","section":"promptMode","source":"chat","previousLength":0,"newLength":1,"content":"x","scorecard":{"transcriptions":4,"futureField":9}}
    """
    let partialDecoded = try JSONDecoder().decode(
      UnifiedSystemPromptHistoryEntry.self, from: Data(partial.utf8))
    #expect(partialDecoded.scorecard?.transcriptions == 4)
    #expect(partialDecoded.scorecard?.prompts == 0)
    #expect(partialDecoded.scorecard?.chatRetries == 0)
  }

  @Test("report reads logs and the stored snapshot; an empty directory is an empty report")
  func reportReadsDirectory() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z"))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("si-scorecard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let stored = ScorecardMetrics(transcriptions: 9, prompts: 4)
    let history = [
      UnifiedSystemPromptHistoryEntry(
        ts: "2026-10-19T04:00:00Z", section: "dictation", source: "auto",
        previousLength: 1, newLength: 1, content: "old", model: nil, scorecard: nil),
      UnifiedSystemPromptHistoryEntry(
        ts: "2026-10-19T06:00:00Z", section: "whisperGlossary", source: "voice-feedback",
        previousLength: 10, newLength: 20, content: #"bachata (not "Butcher")"#,
        model: nil, scorecard: stored),
      UnifiedSystemPromptHistoryEntry(
        ts: "2026-10-19T11:00:00Z", section: "promptMode", source: "chat",
        previousLength: 2, newLength: 3, content: "newer", model: nil, scorecard: nil),
    ]
    let sundayLog = directory.appendingPathComponent("interactions-2026-10-18.jsonl")
    try writeJSONL(
      sundayLog,
      rows: [
        interaction(ts: "2026-10-18T10:00:00Z", mode: "transcription", result: "ich tanze Butcher"),
      ])
    var sundayText = try String(contentsOf: sundayLog, encoding: .utf8)
    sundayText += "not json\n"
    try sundayText.write(to: sundayLog, atomically: true, encoding: .utf8)
    try writeJSONL(
      directory.appendingPathComponent("interactions-2026-10-19.jsonl"),
      rows: [
        interaction(ts: "2026-10-19T08:00:00.481Z", mode: "transcription", result: "ich tanze Butcher"),
      ])
    try writeJSONL(
      directory.appendingPathComponent("signals-2026-10-19.jsonl"),
      rows: [
        signal(ts: "2026-10-19T05:30:00Z", kind: "chatRetry"),
        signal(ts: "2026-10-19T09:00:00Z", kind: "promptRetry"),
      ])
    try writeJSONL(
      directory.appendingPathComponent("system-prompts-history.jsonl"), rows: history)

    let report = SmartImprovementScorecard.report(
      directory: directory, currentGlossary: "Magnus", now: now)
    let change = try #require(report.lastChange)
    #expect(change.before == stored)
    #expect(change.section == "whisperGlossary")
    #expect(change.source == "voice-feedback")
    #expect(change.ts == ISO8601DateFormatter().date(from: "2026-10-19T06:00:00Z"))
    #expect(change.after.transcriptions == 1)
    #expect(change.after.rejectedSpellingHits == 1)
    #expect(change.after.promptRetries == 1)
    #expect(change.after.chatRetries == 0)
    #expect(report.current.transcriptions == 2)
    #expect(report.current.rejectedSpellingHits == 2)

    let filtered = SmartImprovementScorecard.report(
      directory: directory, currentGlossary: "Magnus", section: "dictation", now: now)
    #expect(filtered.lastChange == nil)

    let empty = FileManager.default.temporaryDirectory
      .appendingPathComponent("si-scorecard-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    let emptyReport = SmartImprovementScorecard.report(directory: empty, currentGlossary: "", now: now)
    #expect(emptyReport.weeks.isEmpty)
    #expect(emptyReport.current.isEmpty)
    #expect(emptyReport.lastChange == nil)
  }

  private func interaction(
    ts: String,
    mode: String,
    result: String? = nil,
    selectedText: String? = nil,
    modelResponse: String? = nil
  ) -> InteractionLogEntry {
    InteractionLogEntry(
      ts: ts,
      mode: mode,
      model: nil,
      result: result,
      selectedText: selectedText,
      userInstruction: nil,
      modelResponse: modelResponse,
      text: nil,
      voice: nil,
      audioRef: nil,
      transcriptionModel: nil,
      hadScreenshot: nil,
      latencyMs: nil,
      provider: nil,
      loadMs: nil)
  }

  private func signal(ts: String, kind: String) -> SignalLogEntry {
    SignalLogEntry(ts: ts, kind: kind, refTs: nil, mode: nil, gapMs: nil, detail: nil)
  }

  private func writeJSONL(_ url: URL, rows: [some Encodable]) throws {
    let encoder = JSONEncoder()
    var text = ""
    for row in rows {
      text += String(decoding: try encoder.encode(row), as: UTF8.self) + "\n"
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
  }
}
