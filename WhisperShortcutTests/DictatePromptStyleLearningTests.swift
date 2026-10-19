import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Pins the pure rules Dictate Prompt uses to learn how the user wants text written:
/// which memory facts are style, the hyphen backstop, and which later prompts are edits of
/// the previous output.
@Suite("Dictate Prompt style learning")
struct DictatePromptStyleLearningTests {

  @Test("Only writing-style memory facts are kept, and a Style: marker is stripped")
  func memoryStyleSubset() {
    let facts = [
      "The user's name is Magnus Gödde.",
      "Standardmäßig sollen neu erstellte Google Tasks immer auf den aktuellen Tag (Fälligkeitsdatum) gesetzt werden, wenn der Nutzer die Erstellung einer Task anfordert.",
      "Der Nutzer wünscht ausschließlich einfache Bindestriche (-) statt Gedankenstrichen (—/–) in allen Texten.",
      "Der Nutzer wünscht bei allen Formulierungen und Antworten eine besonders kurze, knappe und natürliche Sprache (kein typisches, blumiges oder längliches KI-Deutsch).",
      "The user wants Grok Bot implementation work to always run on Cursor Grok 4.6 (Cloud Agents default model).",
    ]
    #expect(MemoryStyleRules.styleFacts(from: facts) == [facts[2], facts[3]])
    #expect(MemoryStyleRules.styleFacts(from: ["Style: Always sign off with Magnus"]) == ["Always sign off with Magnus"])
    #expect(MemoryStyleRules.styleFacts(from: ["Lives in Berlin and works short hours"]).isEmpty)
    #expect(MemoryStyleRules.styleFacts(from: ["The dashboard shows the text"]).isEmpty)
    #expect(MemoryStyleRules.prefersShortDashes(styleFacts: facts))
    #expect(!MemoryStyleRules.prefersShortDashes(styleFacts: ["Prefers short answers"]))
    #expect(MemoryStyleRules.promptBlock(styleFacts: []).isEmpty)
  }

  @Test("Em and en dashes become hyphens, except dashes the user wrote or dashes inside code")
  func dashBackstop() {
    #expect(DashBackstop.apply(to: "Hello — world", selection: nil) == "Hello - world")
    #expect(DashBackstop.apply(to: "See 10–12 items", selection: "plain text") == "See 10-12 items")
    #expect(DashBackstop.apply(to: "Hello — world", selection: "kept — as written") == "Hello — world")
    #expect(
      DashBackstop.apply(to: "before ```code — stays``` after — end", selection: nil)
        == "before ```code — stays``` after - end")
    #expect(
      DashBackstop.apply(to: "use `a — b` then — done", selection: nil)
        == "use `a — b` then - done")
    #expect(DashBackstop.apply(to: "start ```code — stays", selection: nil) == "start ```code — stays")
  }

  @Test("A follow-up is the same text again inside five minutes")
  func followUpDetection() {
    let words = PromptFollowUp.words("Hello world this is a test")
    #expect(PromptFollowUp.isFollowUp(selectionWords: words, previousResponseWords: words, gap: 60))
    #expect(!PromptFollowUp.isFollowUp(selectionWords: words, previousResponseWords: words, gap: 301))
    let unrelated = PromptFollowUp.words("trains weather platforms tickets luggage")
    #expect(!PromptFollowUp.isFollowUp(selectionWords: unrelated, previousResponseWords: words, gap: 10))
    #expect(!PromptFollowUp.isFollowUp(selectionWords: [], previousResponseWords: words, gap: 10))
  }

  @Test("Style corrections, transforms, and everything else stay in separate classes")
  func classifyInstruction() {
    #expect(PromptFollowUp.classify(instruction: "kürzer bitte") == .style)
    #expect(PromptFollowUp.classify(instruction: "ohne diese Striche") == .style)
    #expect(PromptFollowUp.classify(instruction: "begrüß ihn per Namen") == .style)
    #expect(PromptFollowUp.classify(instruction: "übersetz das ins Englische") == .transform)
    #expect(PromptFollowUp.classify(instruction: "mach Stichpunkte daraus") == .transform)
    #expect(PromptFollowUp.classify(instruction: "schick das an Peter") == .other)
    #expect(PromptFollowUp.classify(instruction: "Tonne") == .other)
  }

  @Test("chains() keeps one recent edit of the previous output and drops a pair older than the cutoff")
  func chainsKeepTheRecentEdit() {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    func stamp(_ date: Date) -> String { formatter.string(from: date) }
    func parse(_ text: String) -> Date { formatter.date(from: text) ?? .distantPast }

    let recent = Date(timeIntervalSince1970: 1_700_000_000)
    let old = Date(timeIntervalSince1970: 1_600_000_000)
    let previous = "Please send the quarterly report by Friday morning"
    let revised = "Send the quarterly report Friday morning"

    let oldFirst = entry(ts: stamp(old), selectedText: nil, userInstruction: "draft", modelResponse: previous)
    let oldFollowUp = entry(
      ts: stamp(old.addingTimeInterval(30)), selectedText: previous,
      userInstruction: "kürzer bitte", modelResponse: revised)
    let first = entry(
      ts: stamp(recent), selectedText: nil, userInstruction: "polish", modelResponse: previous)
    let followUp = entry(
      ts: stamp(recent.addingTimeInterval(30)), selectedText: previous,
      userInstruction: "kürzer bitte", modelResponse: revised)
    let unrelated = entry(
      ts: stamp(recent.addingTimeInterval(90)),
      selectedText: "trains weather platforms tickets",
      userInstruction: "schick das an Peter", modelResponse: "sent")

    let found = PromptFollowUp.chains(
      in: [unrelated, oldFollowUp, first, oldFirst, followUp],
      since: recent.addingTimeInterval(-10),
      parseDate: parse)
    #expect(found.count == 1)
    #expect(found[0].ts == stamp(recent.addingTimeInterval(30)))
    #expect(found[0].kind == .style)
    #expect(found[0].previousOutput == previous)
    #expect(found[0].instruction == "kürzer bitte")
    #expect(found[0].newOutput == revised)
  }

  @Test("render() is empty for no chains and drops the oldest chain to stay inside maxChars")
  func renderDropsTheOldestChain() {
    #expect(PromptFollowUp.render([], maxFieldChars: 100, maxChars: 1000) == "")

    let older = PromptFollowUp.Chain(
      ts: "2026-01-01T00:00:00Z", kind: .style,
      previousOutput: "alpha", instruction: "shorter", newOutput: "beta")
    let newer = PromptFollowUp.Chain(
      ts: "2026-01-02T00:00:00Z", kind: .other,
      previousOutput: "gamma", instruction: "send it", newOutput: "delta")
    let onlyNewer = PromptFollowUp.render([newer], maxFieldChars: 1000, maxChars: .max)
    let budget = onlyNewer.count
    let trimmed = PromptFollowUp.render([older, newer], maxFieldChars: 1000, maxChars: budget)
    #expect(trimmed == onlyNewer)
    #expect(!trimmed.contains(older.ts))
  }

  private func entry(
    ts: String, selectedText: String?, userInstruction: String?, modelResponse: String?
  ) -> InteractionLogEntry {
    InteractionLogEntry(
      ts: ts,
      mode: "prompt",
      model: nil,
      result: nil,
      selectedText: selectedText,
      userInstruction: userInstruction,
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
}
