import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("UserContext log")
struct UserContextLogTests {

  @Test("Daily filenames stay Gregorian when the cutoff calendar is Buddhist")
  func filesStayGregorianUnderBuddhistCalendar() throws {
    let formatter = UserContextLog.fileNameDateFormatter
    #expect(formatter.calendar.identifier == .gregorian)
    #expect(formatter.locale.identifier == "en_US_POSIX")
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = formatter.timeZone
    let now = try #require(gregorian.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12)))
    #expect(UserContextLog.fileNameDayString(from: now) == "2026-10-21")

    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = formatter.timeZone
    let buddhistFormatter = DateFormatter()
    buddhistFormatter.locale = Locale(identifier: "en_US_POSIX")
    buddhistFormatter.calendar = buddhist
    buddhistFormatter.timeZone = formatter.timeZone
    buddhistFormatter.dateFormat = "yyyy-MM-dd"
    let buddhistDay = buddhistFormatter.string(from: now)
    #expect(buddhistDay != "2026-10-21")

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("user-context-log-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let gregorianName = "interactions-2026-10-21.jsonl"
    try Data("\n".utf8).write(to: dir.appendingPathComponent(gregorianName))
    try Data("\n".utf8).write(to: dir.appendingPathComponent("interactions-\(buddhistDay).jsonl"))

    let listed = UserContextLog.files(
      stream: .interactions, in: dir, lastDays: 3, now: now, calendar: buddhist)
    #expect(listed.map(\.lastPathComponent).contains(gregorianName))
  }

  @Test("Timestamps parse with and without fractional seconds")
  func timestampParsesBothForms() throws {
    let fractional = try #require(UserContextLog.timestamp("2026-10-19T05:28:33.481Z"))
    let plain = try #require(UserContextLog.timestamp("2026-10-19T06:00:00Z"))
    let fractionalOffset = try #require(UserContextLog.timestamp("2026-10-19T10:00:00.481+00:00"))
    let plainOffset = try #require(UserContextLog.timestamp("2026-10-19T10:00:00+00:00"))
    #expect(fractional.timeIntervalSince(plain) < 0)
    #expect(fractionalOffset.timeIntervalSince1970 > 0)
    #expect(plainOffset.timeIntervalSince1970 > 0)
    #expect(UserContextLog.timestamp("not-a-date") == nil)

    let instant = Date(timeIntervalSince1970: 1_760_000_000.481)
    let rendered = UserContextLog.nowString(instant)
    #expect(rendered.contains("."))
    let roundTrip = try #require(UserContextLog.timestamp(rendered))
    #expect(abs(roundTrip.timeIntervalSince(instant)) < 0.001)
  }

  @Test("decodeLines skips blank and malformed lines, and a line with an unknown mode still decodes")
  func decodeLinesSkipsBlankAndMalformedAndKeepsUnknownMode() throws {
    let lines = [
      #"{"ts":"2026-10-19T10:00:00Z","mode":"transcription"}"#,
      #"{"ts":"2026-10-19T10:00:01Z","mode":"prompt"}"#,
      #"{"ts":"2026-10-19T10:00:02Z","mode":"geminiChat"}"#,
      #"{"ts":"2026-10-19T10:00:03Z","mode":"notAMode"}"#,
      "",
      "   ",
      "{not json",
      "{broken",
    ]
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("user-context-log-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("interactions-2026-10-19.jsonl")
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    let rows = UserContextLog.decodeLines([url], as: InteractionLogEntry.self)
    #expect(rows.map(\.mode) == ["transcription", "prompt", "geminiChat", "notAMode"])
    #expect(rows.compactMap(\.interactionMode) == [.transcription, .prompt, .chat])
    #expect(rows[3].interactionMode == nil)
  }

  @Test("A prompt row records field-context characters and history turns; an older row leaves both nil")
  func promptRowRecordsFieldContextAndHistoryTurns() throws {
    let entry = InteractionLogEntry(
      ts: "2026-11-20T12:00:00Z",
      mode: "prompt",
      model: nil,
      result: nil,
      selectedText: nil,
      userInstruction: nil,
      modelResponse: nil,
      text: nil,
      voice: nil,
      transcriptionModel: nil,
      hadScreenshot: false,
      latencyMs: nil,
      provider: nil,
      loadMs: nil,
      fieldContextChars: 412,
      historyTurns: 0)
    let data = try JSONEncoder().encode(entry)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains(#""fieldContextChars":412"#))
    #expect(json.contains(#""historyTurns":0"#))
    let decoded = try JSONDecoder().decode(InteractionLogEntry.self, from: data)
    #expect(decoded.fieldContextChars == 412)
    #expect(decoded.historyTurns == 0)

    let older = Data(#"{"ts":"2026-10-19T10:00:01Z","mode":"prompt"}"#.utf8)
    let olderEntry = try JSONDecoder().decode(InteractionLogEntry.self, from: older)
    #expect(olderEntry.fieldContextChars == nil)
    #expect(olderEntry.historyTurns == nil)
  }
}
