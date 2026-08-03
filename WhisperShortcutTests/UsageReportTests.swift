import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Covers the report a user can hand to the developer.
///
/// The first test here is the reason the file exists. `UsageReport` reads a stream that is full of
/// transcripts, prompts and model replies, and the only thing standing between that stream and an
/// email the user sends is which fields the decoder declares. That guarantee is invisible — nothing
/// fails, nothing logs, the report just quietly starts carrying someone's dictation — so it has to
/// be pinned by a test that fails loudly the moment a content field is added back.
@Suite("Usage report")
struct UsageReportTests {

  // MARK: - Fixtures

  private static let testEnvironment = UsageReport.Environment(
    appVersion: "9.99", osVersion: "26.1", isAppStoreBuild: false)

  /// Writes JSONL fixtures into a fresh temp directory and returns their URLs.
  private func fixtures(interactions: [String], signals: [String]) throws -> (
    interactions: [URL], signals: [URL], cleanup: () -> Void
  ) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-report-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    func write(_ lines: [String], to name: String) throws -> [URL] {
      guard !lines.isEmpty else { return [] }
      let url = dir.appendingPathComponent(name)
      try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
      return [url]
    }

    return (
      try write(interactions, to: "interactions-2026-08-01.jsonl"),
      try write(signals, to: "signals-2026-08-01.jsonl"),
      { try? FileManager.default.removeItem(at: dir) }
    )
  }

  private func report(interactions: [String], signals: [String]) throws -> String {
    let f = try fixtures(interactions: interactions, signals: signals)
    defer { f.cleanup() }
    return UsageReport.render(
      interactionFiles: f.interactions,
      signalFiles: f.signals,
      lastDays: 30,
      environment: Self.testEnvironment)
  }

  private func dictation(
    ts: String = "2026-08-01T10:00:00.000Z", model: String = "gemini-3.5-flash"
  ) -> String {
    """
    {"ts":"\(ts)","mode":"transcription","model":"Gemini Flash","result":"SENTINEL-TRANSCRIPT-9F2A","transcriptionModel":"\(model)"}
    """
  }

  /// `refTs` defaults to `dictation()`'s timestamp, so the measurement window opens at the first
  /// fixture dictation and rates come out over the full count. Tests about the narrowed window
  /// pass an explicit `refTs`.
  private func pasted(
    refTs: String = "2026-08-01T10:00:00.000Z", mode: String = "transcription",
    bundleId: String = "com.apple.mail"
  ) -> String {
    """
    {"ts":"2026-08-01T10:00:05.000Z","kind":"pasted","mode":"\(mode)","refTs":"\(refTs)","detail":{"chars":"120","targetBundleId":"\(bundleId)"}}
    """
  }

  private func restart(
    autoPaste: Bool, gapMs: Int, refTs: String = "2026-08-01T10:00:00.000Z"
  ) -> String {
    """
    {"ts":"2026-08-01T10:01:00.000Z","kind":"dictationRestart","mode":"transcription","refTs":"\(refTs)","gapMs":\(gapMs),"detail":{"autoPasteAvailable":"\(autoPaste)"}}
    """
  }

  private func chatTurn(
    ts: String = "2026-08-01T12:00:00.000Z", model: String = "gemini-3.6-flash"
  ) -> String {
    """
    {"ts":"\(ts)","mode":"geminiChat","model":"\(model)","userInstruction":"SENTINEL-INSTRUCTION-4B71","modelResponse":"SENTINEL-RESPONSE-C03D"}
    """
  }

  private func chatRetry(refTs: String = "2026-08-01T12:00:00.000Z") -> String {
    """
    {"ts":"2026-08-01T12:05:00.000Z","kind":"chatRetry","mode":"geminiChat","refTs":"\(refTs)","detail":{"model":"gemini-3.6-flash"}}
    """
  }

  private func chatStopped(reason: String, refTs: String = "2026-08-01T12:00:00.000Z") -> String {
    """
    {"ts":"2026-08-01T12:06:00.000Z","kind":"chatStopped","mode":"geminiChat","refTs":"\(refTs)","detail":{"reason":"\(reason)","partialChars":"180","dropped":"0"}}
    """
  }

  // MARK: - The leak test

  @Test("No user content reaches the report, whatever the log holds")
  func neverLeaksContent() throws {
    let sentinels = [
      "SENTINEL-TRANSCRIPT-9F2A", "SENTINEL-INSTRUCTION-4B71", "SENTINEL-RESPONSE-C03D",
      "SENTINEL-SELECTED-88EE", "SENTINEL-VOICE-1A5C", "SENTINEL-AUDIOREF-77BD",
    ]
    let loaded = """
      {"ts":"2026-08-01T10:00:00.000Z","mode":"transcription","model":"Gemini Flash","result":"SENTINEL-TRANSCRIPT-9F2A","transcriptionModel":"gemini-3.5-flash","audioRef":"SENTINEL-AUDIOREF-77BD","voice":"SENTINEL-VOICE-1A5C"}
      """
    let promptRow = """
      {"ts":"2026-08-01T11:00:00.000Z","mode":"prompt","model":"Gemini Pro","selectedText":"SENTINEL-SELECTED-88EE","userInstruction":"SENTINEL-INSTRUCTION-4B71","modelResponse":"SENTINEL-RESPONSE-C03D","hadScreenshot":true}
      """
    let chatRow = """
      {"ts":"2026-08-01T12:00:00.000Z","mode":"geminiChat","model":"Gemini Pro","userInstruction":"SENTINEL-INSTRUCTION-4B71","modelResponse":"SENTINEL-RESPONSE-C03D"}
      """

    let text = try report(
      interactions: [loaded, promptRow, chatRow],
      signals: [pasted(), restart(autoPaste: true, gapMs: 8000)])

    for sentinel in sentinels {
      #expect(!text.contains(sentinel), "report leaked \(sentinel):\n\(text)")
    }
    // Sanity: the fixtures really did produce a populated report, so the assertions above are not
    // passing because nothing was rendered at all.
    #expect(text.contains("Dictation"))
    #expect(text.contains("Dictate Prompt"))
    #expect(text.contains("Chat"))
  }

  // MARK: - Arithmetic

  @Test("Delivery and restart rates match hand-computed fixtures")
  func ratesAreCorrect() throws {
    let text = try report(
      interactions: (0..<10).map { dictation(ts: "2026-08-01T10:0\($0):00.000Z") },
      signals: Array(repeating: pasted(), count: 8) + [restart(autoPaste: true, gapMs: 8200)])

    #expect(text.contains("10 dictations"))
    #expect(text.contains("80% delivered"))
    #expect(text.contains("10% restarted (1)"))
    #expect(text.contains("median restart gap 8.2 s"))
    #expect(text.contains("models: gemini-3.5-flash 100%"))
  }

  /// The failure this pins was found by looking at a real report: outcome signals shipped weeks
  /// after interaction logging, so dividing by every dictation in the window rendered an app that
  /// delivered almost everything as "2.7% delivered". Every future signal will reintroduce the same
  /// skew on the day it ships.
  @Test("Rates are measured only over dictations that could have produced a signal")
  func ratesUseTheSignalWindow() throws {
    let beforeSignals = (0..<8).map { dictation(ts: "2026-07-20T09:0\($0):00.000Z") }
    let afterSignals = (0..<2).map { dictation(ts: "2026-08-01T10:0\($0):00.000Z") }

    // The paste judges the first of the two recent dictations, so the window opens there.
    let text = try report(
      interactions: beforeSignals + afterSignals,
      signals: [pasted(refTs: "2026-08-01T10:00:00.000Z")])

    #expect(text.contains("10 dictations"))
    #expect(text.contains("of the 2 since outcome tracking began: 50% delivered"))
    #expect(!text.contains("10% delivered"))
  }

  @Test("Restarts from builds without auto-paste are excluded from the rate")
  func restartsWithoutAutoPasteAreIgnored() throws {
    let text = try report(
      interactions: (0..<10).map { dictation(ts: "2026-08-01T10:0\($0):00.000Z") },
      signals: [pasted()] + Array(repeating: restart(autoPaste: false, gapMs: 3000), count: 5))

    #expect(text.contains("0% restarted (0)"))
    #expect(!text.contains("median restart gap"))
  }

  @Test("Without any delivery signal the gap is labelled, not reported as zero")
  func unmeasurableDeliveryIsLabelled() throws {
    let f = try fixtures(
      interactions: [dictation()], signals: [restart(autoPaste: false, gapMs: 3000)])
    defer { f.cleanup() }

    let appStore = UsageReport.render(
      interactionFiles: f.interactions, signalFiles: f.signals,
      environment: UsageReport.Environment(
        appVersion: "9.99", osVersion: "26.1", isAppStoreBuild: true))

    #expect(appStore.contains("unavailable in App Store builds"))
    #expect(!appStore.contains("delivered"))
    #expect(!appStore.contains("0% restarted"))
  }

  /// A main-thread stall cancels the send through the very same `CancellationError` path the Stop
  /// button uses. Counting those as rejections would turn every freeze into evidence against the
  /// model — the opposite of what the report is for.
  @Test("A watchdog cancellation is not counted as the user rejecting an answer")
  func stallStopsAreNotVerdicts() throws {
    let turns = (0..<4).map { chatTurn(ts: "2026-08-01T12:0\($0):00.000Z") }

    let text = try report(
      interactions: turns,
      signals: [
        chatRetry(), chatStopped(reason: "user"),
        chatStopped(reason: "stall"), chatStopped(reason: "stall"),
      ])

    #expect(text.contains("25% retried (1) · 1 stopped mid-stream"))
    // Stops are a count, never a rate: a send killed mid-stream never becomes a logged turn, so
    // the turn count is not a denominator it belongs to.
    #expect(!text.contains("% stopped"))
  }

  /// `refTs` comes from an in-memory marker, so a verdict delivered right after an app relaunch —
  /// pressing Retry on an answer from before the update — carries none. This is not hypothetical:
  /// the first four `chatRetry` signals ever recorded on a real machine all looked like this.
  ///
  /// Both naive readings are wrong. Requiring `refTs` drops every one of them and removes the chat
  /// line entirely. Counting them against a window anchored on their own timestamps divides by a
  /// denominator that excludes the very turns they judge — on the real data that read as a 33%
  /// retry rate. So they are reported as a count, with no rate attached.
  @Test("A verdict logged after a relaunch is counted, but never turned into a rate")
  func signalsWithoutRefTsAreCountedNotRated() throws {
    let turns = (0..<4).map { chatTurn(ts: "2026-08-01T12:1\($0):00.000Z") }
    let orphanRetry = """
      {"ts":"2026-08-01T12:05:00.000Z","kind":"chatRetry","mode":"geminiChat","detail":{"model":"gemini-3.6-flash"}}
      """

    let text = try report(interactions: turns, signals: [orphanRetry])

    #expect(text.contains("1 retried"))
    #expect(!text.contains("% retried"))
    #expect(!text.contains("since outcome tracking began"))
  }

  // MARK: - Shape

  @Test("Sections with no data are omitted rather than rendered empty")
  func emptySectionsAreOmitted() throws {
    let text = try report(interactions: [dictation()], signals: [])

    #expect(text.contains("Dictation"))
    #expect(!text.contains("Dictate Prompt"))
    #expect(!text.contains("Chat"))
    #expect(!text.contains("Pasted into"))
  }

  @Test("An empty log yields a report that says so, not a wall of zeroes")
  func emptyLogIsExplicit() throws {
    let text = try report(interactions: [], signals: [])
    #expect(text.contains("No usage data recorded."))
  }

  @Test("The report stays within the URL budget and every channel still builds")
  func staysWithinURLBudget() throws {
    let interactions = (0..<40).map {
      dictation(ts: "2026-08-01T10:00:00.000Z", model: "some-quite-long-transcription-model-\($0)")
    }
    let signals = (0..<60).map { pasted(bundleId: "com.example.some.long.bundle.identifier.\($0)") }
    let text = try report(interactions: interactions, signals: signals)

    #expect(text.count <= UsageReport.maxCharacters)
    #expect(text.hasSuffix("no transcripts, prompts, replies, or audio."))
    for channel in FeedbackLinks.Channel.allCases {
      #expect(
        FeedbackLinks.url(for: channel, context: text) != nil,
        "\(channel.rawValue) could not carry the report")
    }
  }
}
