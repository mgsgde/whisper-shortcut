import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The three gaps that kept a tuning model from seeing everything: error lines, Read Aloud and
/// chat tool calls, and the history of configuration changes.
@Suite("LLM log gaps")
struct LogGapsTests {

  // MARK: - Gap A: include_errors

  private func errorFile(_ day: String, _ lines: [String]) -> ErrorLogReader.DayFile {
    ErrorLogReader.DayFile(day: day, text: lines.joined(separator: "\n") + "\n")
  }

  private var noon: Date {
    let f = UserContextLog.makeFileNameDateFormatter(dateFormat: "yyyy-MM-dd HH:mm")
    f.timeZone = .current
    return f.date(from: "2026-11-09 12:00")!
  }

  @Test("include_errors parses as a boolean, a string or absent")
  func parseFlag() {
    #expect(InteractionLogQuery.parse([:]).query?.includeErrors == false)
    #expect(InteractionLogQuery.parse(["include_errors": true]).query?.includeErrors == true)
    #expect(InteractionLogQuery.parse(["include_errors": "true"]).query?.includeErrors == true)
    #expect(InteractionLogQuery.parse(["include_errors": false]).query?.includeErrors == false)
  }

  @Test("Error lines get a full local timestamp, newest first, long lines are cut")
  func parsesLines() throws {
    var q = InteractionLogQuery()
    q.includeErrors = true
    let long = String(repeating: "x", count: 500)
    let lines = ErrorLogReader.lines(
      from: [
        errorFile("2026-11-08", ["[23:59:59.001] ERROR ❌ [A.swift:1] f: yesterday"]),
        errorFile("2026-11-09", [
          "[11:26:01.662] ERROR ❌ [File.swift:245] func: first",
          "garbage without a prefix",
          "[11:30:00.000] ERROR ❌ [B.swift:2] g: \(long)",
        ]),
      ], query: q, now: noon)
    #expect(lines.count == 3)
    #expect(lines[0].text.hasPrefix("ERROR ❌ [B.swift:2] g: "))
    #expect(lines[0].text.count <= ErrorLogReader.maxLineCharacters + 1)
    #expect(lines[1].text == "ERROR ❌ [File.swift:245] func: first")
    #expect(lines[2].text.hasSuffix("yesterday"))
    let parsed = try #require(UserContextLog.timestamp(lines[1].ts))
    #expect(abs(parsed.timeIntervalSince(lines[1].date)) < 0.001)
    #expect(lines[1].ts.contains("T11:26:01.662"))
    #expect(lines[1].date < lines[0].date)
  }

  @Test("Error lines respect since and the query filter")
  func filters() {
    var q = InteractionLogQuery()
    q.since = noon.addingTimeInterval(-3600)  // 11:00
    q.query = "GÉMINI"
    let lines = ErrorLogReader.lines(
      from: [errorFile("2026-11-09", [
        "[09:00:00.000] ERROR gemini too early",
        "[11:10:00.000] ERROR gemini request failed",
        "[11:20:00.000] ERROR whisper failed",
      ])], query: q, now: noon)
    #expect(lines.map(\.text) == ["ERROR gemini request failed"])
  }

  @Test("At most 50 error lines")
  func capsAtFifty() {
    var q = InteractionLogQuery()
    q.includeErrors = true
    let many = (0..<80).map { String(format: "[10:%02d:00.000] ERROR n%d", $0 % 60, $0) }
    let lines = ErrorLogReader.lines(from: [errorFile("2026-11-09", many)], query: q, now: noon)
    #expect(lines.count == ErrorLogReader.maxLines)
  }

  @Test("Errors appear in the result only when asked for, and count against the budget")
  func resultErrors() {
    var q = InteractionLogQuery()
    let page = InteractionLogReader.Page(records: [], totalAvailable: 0, nextOffset: nil)
    let lines = (0..<40).map {
      ErrorLogLine(ts: "2026-11-09T10:00:0\($0 % 10).000+01:00", date: noon, text: String(repeating: "e", count: 250))
    }
    #expect(InteractionLogReader.result(page, query: q, fieldCap: 800, budget: 4_000, errors: lines)["errors"] == nil)
    q.includeErrors = true
    let out = InteractionLogReader.result(page, query: q, fieldCap: 800, budget: 4_000, errors: lines)
    let rows = out["errors"] as? [[String: Any]] ?? []
    #expect(!rows.isEmpty && rows.count < 40)
    #expect(out["errors_truncated"] as? Bool == true)
    #expect(out["errors_total"] as? Int == 40)
  }

  // MARK: - Gap B

  @Test("toolCalls round-trip, are omitted when empty, and old rows decode")
  func toolCalls() throws {
    let calls = [
      InteractionToolCall(name: "gmail_search", ok: true),
      InteractionToolCall(name: "google_tasks_create", ok: false, error: String(repeating: "e", count: 400)),
    ]
    #expect(calls[1].error?.count == InteractionToolCall.maxErrorCharacters)
    func entry(_ calls: [InteractionToolCall]?) -> InteractionLogEntry {
      InteractionLogEntry(
        ts: "t", mode: "geminiChat", model: nil, result: nil, selectedText: nil, userInstruction: "q",
        modelResponse: "a", text: nil, voice: nil, transcriptionModel: nil, hadScreenshot: nil,
        latencyMs: nil, provider: nil, loadMs: nil, toolCalls: calls)
    }
    let data = try JSONEncoder().encode(entry(calls))
    let back = try JSONDecoder().decode(InteractionLogEntry.self, from: data)
    #expect(back.toolCalls == calls)
    let none = String(data: try JSONEncoder().encode(entry([])), encoding: .utf8) ?? ""
    #expect(!none.contains("toolCalls"))
    let old = #"{"ts":"t","mode":"geminiChat","userInstruction":"q"}"#
    #expect(try JSONDecoder().decode(InteractionLogEntry.self, from: Data(old.utf8)).toolCalls == nil)

    let record = ChatToolCallRecord(
      name: "gmail_read", argsJSON: "{\"secret\":1}", resultJSON: "{}", status: .failed, summary: "boom")
    #expect(InteractionToolCall(record: record) == InteractionToolCall(name: "gmail_read", ok: false, error: "boom"))
    let item = InteractionLogReader.item(
      InteractionLogReader.Record(entry: entry(calls), signals: []), fieldCap: 800)
    #expect((item["toolCalls"] as? [[String: Any]])?.count == 2)
    #expect(!String(describing: item["toolCalls"] ?? "").contains("secret"))
  }

  @Test("readAloud is a mode the query tool can filter on")
  func readAloudMode() {
    #expect(InteractionMode.readAloud.rawValue == "readAloud")
    for raw in ["read_aloud", "readAloud", "Read_Aloud"] {
      #expect(InteractionLogQuery.modeValue(raw) == "readAloud")
    }
    #expect(InteractionLogQuery.parse(["mode": "read_aloud"]).query?.mode == "readAloud")
    #expect(OutcomeSignal.readAloudStopped.rawValue == "readAloudStopped")
  }

  // MARK: - Gap C

  private func scratchStore() -> SystemPromptsStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loggaps-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return SystemPromptsStore(contextDirectoryURL: dir)
  }

  private func rows(_ store: SystemPromptsStore) -> [UnifiedSystemPromptHistoryEntry] {
    ConfigHistoryReader.load(from: store.historyFileURL)
  }

  @Test("A Settings write appends exactly one row; the same content again appends none")
  func settingsWrite() {
    let store = scratchStore()
    #expect(store.updateSection(.promptMode, content: "Be brief.", source: .settings))
    #expect(rows(store).count == 1)
    #expect(rows(store).first?.source == "settings")
    #expect(rows(store).first?.section == "promptMode")
    #expect(rows(store).first?.content == "Be brief.")
    #expect(store.updateSection(.promptMode, content: "Be brief.", source: .settings))
    #expect(store.updateSection(.promptMode, content: "  Be brief.\n", source: .settings))
    #expect(rows(store).count == 1)
  }

  @Test("The glossary shortcut and the chat path each append exactly one row")
  func otherSources() {
    let store = scratchStore()
    #expect(store.appendToWhisperGlossary("Wianco", source: .glossaryShortcut) == .added("Wianco"))
    #expect(store.appendToWhisperGlossary("Wianco", source: .glossaryShortcut) == .duplicate("Wianco"))
    #expect(rows(store).map(\.source) == ["glossaryShortcut"])
    store.updateSection(.chat, content: "Answer in German.", source: .chat)
    #expect(rows(store).map(\.source) == ["glossaryShortcut", "chat"])
    #expect(PromptHistorySource.settings.displayName == "Settings")
    #expect(PromptHistorySource.displayName(for: "glossaryShortcut") == "Glossary shortcut")
  }

  @Test("Line diff is computed against the previous row of the same section")
  func diff() {
    let store = scratchStore()
    store.updateSection(.whisperGlossary, content: "Alpha\nBeta", source: .settings)
    store.updateSection(.promptMode, content: "Rule A", source: .settings)
    store.updateSection(.whisperGlossary, content: "Alpha\nGamma", source: .chat)
    let out = ConfigHistoryReader.result(rows: rows(store), query: ConfigHistoryQuery())
    let changes = out["changes"] as? [[String: Any]] ?? []
    #expect(changes.count == 3)
    #expect(changes[0]["section"] as? String == "whisper_glossary")
    #expect(changes[0]["source_raw"] as? String == "chat")
    #expect(changes[0]["added"] as? [String] == ["Gamma"])
    #expect(changes[0]["removed"] as? [String] == ["Beta"])
    #expect(changes[2]["diff"] != nil)
    var q = ConfigHistoryQuery()
    q.section = .promptMode
    #expect((ConfigHistoryReader.result(rows: rows(store), query: q)["changes"] as? [Any])?.count == 1)
    #expect(ConfigHistoryQuery.parse(["section": "nope"]).error != nil)
    #expect(ConfigHistoryQuery.parse(["limit": 5000]).query?.limit == ConfigHistoryQuery.maxLimit)
  }

  @Test("Diff lines are capped")
  func diffCaps() {
    let new = (0..<50).map { _ in String(repeating: "z", count: 400) + UUID().uuidString }.joined(separator: "\n")
    let first = UnifiedSystemPromptHistoryEntry(
      ts: "2026-11-01T10:00:00.000Z", section: "geminiChat", source: "settings", previousLength: 0,
      newLength: 0, content: "", model: nil)
    let second = UnifiedSystemPromptHistoryEntry(
      ts: "2026-11-02T10:00:00.000Z", section: "geminiChat", source: "settings", previousLength: 0,
      newLength: 1, content: new, model: nil)
    let changes = ConfigHistoryReader.result(rows: [first, second], query: ConfigHistoryQuery())["changes"] as? [[String: Any]] ?? []
    let added = changes[0]["added"] as? [String] ?? []
    #expect(added.count == ConfigHistoryQuery.maxDiffLines)
    #expect(added.allSatisfy { $0.count <= ConfigHistoryQuery.maxLineCharacters + 1 })
    #expect(changes[0]["added_more"] as? Int == 20)
  }
}
