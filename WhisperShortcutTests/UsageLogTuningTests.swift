import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The tuning surface that replaced Smart Improvement (removed 2026-11-02): the usage log's new
/// context fields, the shared read path, and the chat's `update_app_instructions` /
/// `read_recent_interactions` tools. The glossary cases pin the incident that removed the feature:
/// an automatic rewrite shrank a curated glossary from 234 to 115 characters.
@MainActor
@Suite("Usage log tuning")
struct UsageLogTuningTests {

  private static let curatedGlossary = """
  Christoph Michelbach (not "m1cm1")
  Wianco (not "Vianco")
  sabaki.dance (not "Bachi dance")
  """

  // MARK: - Log rows

  @Test("Old rows with audioRef and new rows with the context fields both decode")
  func oldAndNewRowsDecode() throws {
    let old = #"{"ts":"2026-07-01T10:00:00Z","mode":"transcription","result":"hi","audioRef":"20260701T100000000-ABCDEF.wav","transcriptionModel":"gemini-3.5-flash"}"#
    let decodedOld = try JSONDecoder().decode(InteractionLogEntry.self, from: Data(old.utf8))
    #expect(decodedOld.result == "hi")
    #expect(decodedOld.appName == nil)
    #expect(decodedOld.promptVersion == nil)

    let entry = InteractionLogEntry(
      ts: "t", mode: "transcription", model: nil, result: "x", selectedText: nil, userInstruction: nil,
      modelResponse: nil, text: nil, voice: nil, transcriptionModel: nil, hadScreenshot: nil,
      latencyMs: nil, provider: nil, loadMs: nil,
      context: InteractionContext(
        appBundleId: "com.apple.mail", appName: "Mail", durationMs: 1234, language: "de", promptVersion: "abcd1234"))
    let data = try JSONEncoder().encode(entry)
    #expect(String(data: data, encoding: .utf8)?.contains("audioRef") == false)
    let again = try JSONDecoder().decode(InteractionLogEntry.self, from: data)
    #expect(again.appBundleId == "com.apple.mail")
    #expect(again.appName == "Mail")
    #expect(again.durationMs == 1234)
    #expect(again.language == "de")
    #expect(again.promptVersion == "abcd1234")
  }

  @Test("A prompt-history row with the old scorecard snapshot still decodes")
  func historyRowWithScorecardDecodes() throws {
    let row = #"{"ts":"t","section":"whisperGlossary","source":"auto","previousLength":234,"newLength":115,"content":"x","model":"m","scorecard":{"glossaryLength":115}}"#
    let decoded = try JSONDecoder().decode(UnifiedSystemPromptHistoryEntry.self, from: Data(row.utf8))
    #expect(decoded.newLength == 115)
    #expect(PromptHistorySource.displayName(for: decoded.source).isEmpty == false)
  }

  @Test("promptVersion is a stable 8-hex hash, and 'default' for an empty section")
  func promptVersion() {
    let a = InteractionContext.promptVersion(of: "Rule one.")
    #expect(a.count == 8)
    #expect(a.allSatisfy(\.isHexDigit))
    #expect(InteractionContext.promptVersion(of: "  Rule one.\n") == a)
    #expect(InteractionContext.promptVersion(of: "Rule two.") != a)
    #expect(InteractionContext.promptVersion(of: nil) == "default")
    #expect(InteractionContext.promptVersion(of: " \n") == "default")
  }

  @Test("Signals are kept longer than the texts they judge")
  func retention() {
    #expect(ContextLogger.retentionDays(for: .interactions) == ContextLogger.contentRetentionDays)
    #expect(ContextLogger.retentionDays(for: .signals) == ContextLogger.signalRetentionDays)
    #expect(ContextLogger.signalRetentionDays > ContextLogger.contentRetentionDays)
  }

  // MARK: - Query parsing

  @Test("since accepts a day, a timestamp and a relative span; rejects prose")
  func sinceParsing() throws {
    let now = try #require(UserContextLog.timestamp("2026-11-02T12:00:00Z"))
    let rel = try #require(InteractionLogQuery.parseSince("14d", now: now))
    #expect(abs(now.timeIntervalSince(rel) - 14 * 86_400) < 3_700)  // DST may shift by an hour
    let hours = try #require(InteractionLogQuery.parseSince("48h", now: now))
    #expect(abs(now.timeIntervalSince(hours) - 48 * 3_600) < 3_700)
    #expect(InteractionLogQuery.parseSince("2026-10-01T08:00:00Z", now: now) == UserContextLog.timestamp("2026-10-01T08:00:00Z"))
    #expect(InteractionLogQuery.parseSince("2026-10-01", now: now) != nil)
    #expect(InteractionLogQuery.parseSince("last tuesday", now: now) == nil)
    #expect(InteractionLogQuery.parse(["since": "soon"]).error != nil)
    #expect(InteractionLogQuery.parse(["mode": "chat"]).query?.mode == InteractionMode.chat.rawValue)
    #expect(InteractionLogQuery.parse(["limit": 500]).query?.limit == InteractionLogQuery.maxLimit)
  }

  @Test("The window never reaches past the retention limit")
  func windowFloor() throws {
    let now = try #require(UserContextLog.timestamp("2026-11-02T12:00:00Z"))
    var q = InteractionLogQuery()
    q.since = Calendar.current.date(byAdding: .day, value: -400, to: now)
    #expect(q.windowDays(now: now) <= ContextLogger.contentRetentionDays + 1)
    // A DST change inside the week can add an hour, which rounds up to one more day.
    let defaultDays = InteractionLogQuery().windowDays(now: now)
    #expect(defaultDays >= InteractionLogQuery.defaultDays && defaultDays <= InteractionLogQuery.defaultDays + 1)
  }

  // MARK: - Chat tools

  @Test("read_recent_interactions is declared only while usage data is saved")
  func readToolGatedOnUsageData() {
    func names(_ usage: Bool) -> Set<String> {
      Set(ChatToolRegistry.allDeclarations(
        calendarConnected: false, trelloConnected: false, imageGenerationAvailable: false,
        meetingContext: false, workspaceAvailable: false, workspaceWritable: false,
        mailAvailable: false, mailAccountsConnected: false, usageDataAvailable: usage, chatProvider: .gemini
      ).compactMap { $0["name"] as? String })
    }
    #expect(names(true).contains(ChatToolRegistry.readRecentInteractionsToolName))
    #expect(!names(false).contains(ChatToolRegistry.readRecentInteractionsToolName))
    #expect(!ChatToolRegistry.requiresUserApproval(ChatToolRegistry.readRecentInteractionsToolName))
  }

  @Test("update_app_instructions offers dictation, chat and whisper_glossary next to dictate_prompt")
  func instructionTargets() throws {
    let decl = try #require(ChatToolRegistry.instructionsFunctionDeclarations.first)
    let params = try #require(decl["parameters"] as? [String: Any])
    let props = try #require(params["properties"] as? [String: Any])
    let section = try #require(props["section"] as? [String: Any])
    let sections = Set(try #require(section["enum"] as? [String]))
    #expect(sections == ["dictation", "dictate_prompt", "chat", "whisper_glossary"])
    #expect(Set(ChatToolRegistry.editableInstructionSections.keys) == sections)
    let description = try #require(decl["description"] as? String)
    #expect(description.contains("read the logs"))
    #expect(description.contains("ask"))
    #expect(description.contains("Never delete glossary entries"))
  }

  @Test("The approval card names the section the call writes")
  func approvalNamesSection() {
    let summary = ChatToolRegistry.approvalSummary(
      name: ChatToolRegistry.updateInstructionsToolName,
      args: ["section": "whisper_glossary", "action": "append", "text": "Wianco"])
    #expect(summary.contains(MCPProposalWindows.displayName(.whisperGlossary)))
    #expect(summary.contains("Wianco"))
  }

  @Test("A glossary replace that drops a curated entry is detected; re-annotating is not a drop")
  func glossaryDrops() {
    let shrunk = "Wianco (not \"Vianco\")"
    #expect(
      Set(ChatToolRegistry.glossaryEntriesDropped(from: Self.curatedGlossary, by: shrunk))
        == ["Christoph Michelbach", "sabaki.dance"])
    let reannotated = Self.curatedGlossary + "\nWianco (not \"Viancko\")"
    #expect(ChatToolRegistry.glossaryEntriesDropped(from: Self.curatedGlossary, by: reannotated).isEmpty)
    #expect(ChatToolRegistry.glossaryEntriesDropped(from: Self.curatedGlossary, by: Self.curatedGlossary.lowercased()).isEmpty)
  }
}
