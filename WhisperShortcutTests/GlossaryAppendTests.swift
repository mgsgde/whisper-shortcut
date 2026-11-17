import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// "Add Selection to Glossary" writes straight into the file every dictation is conditioned with,
/// from a keystroke, with no review step. The rules that keep that safe — it is a term, it is not
/// already there, it still fits in what Whisper reads — are therefore asserted rather than trusted.
@Suite("Glossary append")
struct GlossaryAppendTests {

  @Test("A selection is trimmed to a term, not stored as the user happened to select it")
  func selectionIsNormalised() {
    #expect(SystemPromptsStore.normaliseTerm("  Iliosakralgelenk  ") == "Iliosakralgelenk")
    #expect(SystemPromptsStore.normaliseTerm("Iliosakralgelenk.") == "Iliosakralgelenk")
    #expect(SystemPromptsStore.normaliseTerm("\"Gödde\",") == "Gödde")
    // Line breaks inside a selection collapse; a term dragged across a wrap is still one term.
    #expect(SystemPromptsStore.normaliseTerm("Fascia\n thoracolumbalis") == "Fascia thoracolumbalis")
    // Capitalisation is part of the spelling being asserted and must survive untouched.
    #expect(SystemPromptsStore.normaliseTerm("HVLA") == "HVLA")
  }

  @Test("Membership ignores case and accepts both separators users actually write")
  func duplicateDetectionMatchesHowPeopleWrite() {
    let glossary = "Iliosakralgelenk, Fascia thoracolumbalis\nHVLA, Gödde"
    #expect(SystemPromptsStore.glossaryContains("Iliosakralgelenk", in: glossary))
    #expect(SystemPromptsStore.glossaryContains("iliosakralgelenk", in: glossary))
    // Newline-separated entries count too — the editor is free text, not a comma-only field.
    #expect(SystemPromptsStore.glossaryContains("HVLA", in: glossary))
    #expect(SystemPromptsStore.glossaryContains("Fascia thoracolumbalis", in: glossary))
    #expect(!SystemPromptsStore.glossaryContains("Sakrumtorsion", in: glossary))
    // A substring of an entry is not an entry: "Fascia" must still be addable.
    #expect(!SystemPromptsStore.glossaryContains("Fascia", in: glossary))
    // Diacritics and a rejected spelling are the same term. "Goedde" is not: oe does not fold to ö.
    #expect(SystemPromptsStore.glossaryContains("Gödde", in: glossary))
    #expect(SystemPromptsStore.glossaryContains("godde", in: "Gödde"))
    #expect(SystemPromptsStore.glossaryContains("Gödde", in: "Goedde (not \"Gödde\")"))
    #expect(!SystemPromptsStore.glossaryContains("Gödde", in: "Goedde"))
  }

  /// The failure this guards against is not a crash but a silently degraded transcript: a whole
  /// sentence in the conditioning text biases Whisper toward reproducing it.
  @Test("A sentence is refused; a term is accepted")
  func sentencesAreRefused() {
    let store = SystemPromptsStore.shared
    let sentence = "Die Patientin klagt über ziehende Schmerzen im unteren Rücken seit drei Wochen"
    #expect(store.appendToWhisperGlossary(sentence, source: .glossaryShortcut) == .notATerm(sentence))
    #expect(store.appendToWhisperGlossary("   ", source: .glossaryShortcut) == .notATerm(""))
  }

  @Test("Appending to a line-based glossary starts a new line; a comma list stays comma-joined")
  func appendPlacement() {
    #expect(SystemPromptsStore.appendingEntry("Lasègue", to: "") == "Lasègue")
    #expect(SystemPromptsStore.appendingEntry("Lasègue", to: "HVLA, Gödde") == "HVLA, Gödde, Lasègue")
    let annotated = "Supraspinatus (not \"Super Spinatus\")"
    let a = SystemPromptsStore.appendingEntry("Lasègue", to: annotated)
    #expect(a == annotated + "\nLasègue")
    let doc = GlossaryDocument.parse(a)
    #expect(doc.entries.map(\.term) == ["Supraspinatus", "Lasègue"])
    #expect(doc.entries[1].rejectedSpellings.isEmpty)
    // The transcription path builds its correction from the line text: it must not become
    // "Supraspinatus, Lasègue" (one bogus CTC keyword, one bogus tie-breaker).
    #expect(a.components(separatedBy: "\n").map(GlossaryDocument.lineTermText) == ["Supraspinatus", "Lasègue"])
    let multi = "HVLA\nGödde"
    #expect(SystemPromptsStore.appendingEntry("Lasègue", to: multi) == multi + "\nLasègue")
  }

  private func scratchStore() -> SystemPromptsStore {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("glossary-merge-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return SystemPromptsStore(contextDirectoryURL: dir)
  }

  @Test("Two queues merging at once lose no term")
  func concurrentMergeKeepsEveryTerm() {
    let store = scratchStore()
    let group = DispatchGroup()
    let queues = [
      DispatchQueue(label: "glossary-merge-a"),
      DispatchQueue(label: "glossary-merge-b"),
    ]
    for i in 0..<30 {
      group.enter()
      queues[i % 2].async {
        _ = store.mergeGlossary([String(format: "Zz%02dterm", i)], source: .chat)
        group.leave()
      }
    }
    #expect(group.wait(timeout: .now() + 10) == .success)
    let glossary = store.loadWhisperGlossary()
    let terms = Set(GlossaryDocument.parse(glossary).entries.map(\.term))
    for i in 0..<30 {
      #expect(terms.contains(String(format: "Zz%02dterm", i)))
    }
    #expect(glossary.count <= SystemPromptsStore.glossaryCharBudget)
  }

  @Test("Each term reports duplicate or budget, and the file stops at 1,200")
  func perTermDuplicateAndBudget() {
    let store = scratchStore()
    let base = String(repeating: "x", count: SystemPromptsStore.glossaryCharBudget - 7)
    store.updateSection(.whisperGlossary, content: base, source: .settings)
    let results = store.mergeGlossary(["Hello", "Hello", "X"], source: .glossaryShortcut)
    #expect(results == [.added("Hello"), .duplicate("Hello"), .budgetExceeded("X")])
    let saved = store.loadWhisperGlossary()
    #expect(saved == base + ", Hello")
    #expect(saved.count == SystemPromptsStore.glossaryCharBudget)
    #expect(!saved.contains(", X"))
  }

  @Test("The fast learner cannot push the glossary past 1,200, and it keeps a comma list")
  func learnerUsesStoreBudgetAndSeparator() {
    let store = scratchStore()
    let learner = GlossaryFastLearner(store: store)
    let over = String(repeating: "x", count: 1_500)
    store.updateSection(.whisperGlossary, content: over, source: .settings)
    let refused = learner.rememberTerm("Qqzxvkrpl", misheardAs: nil)
    #expect(refused["error"] != nil)
    #expect(store.loadWhisperGlossary() == over)
    #expect(over.count > SystemPromptsStore.glossaryCharBudget)

    store.updateSection(.whisperGlossary, content: "Alpha, Beta", source: .settings)
    let added = learner.rememberTerm("Qqzxvkrpl", misheardAs: nil)
    #expect(added["status"] as? String == "added")
    let saved = store.loadWhisperGlossary()
    #expect(saved.hasPrefix("Alpha, Beta, "))
    #expect(!saved.contains("\n"))
    #expect(saved.count <= SystemPromptsStore.glossaryCharBudget)
  }
}

@Suite("Config drift")
struct ConfigDriftTests {

  @Test("Config history names Read Aloud the way MCP does")
  func readAloudSectionName() {
    #expect(Set(ConfigHistoryQuery.sectionNames) == Set(MCPConfigTools.sections.map(\.name)))
    #expect(ConfigHistoryQuery.section(named: "read_aloud_rewrite") == .readAloudRewrite)
    #expect(ConfigHistoryQuery.name(forStoredSection: SystemPromptSection.readAloudRewrite.rawValue) == "read_aloud_rewrite")
    let parsed = ConfigHistoryQuery.parse(["section": "read_aloud_rewrite"])
    #expect(parsed.error == nil)
    #expect(parsed.query?.section == .readAloudRewrite)
  }

  @Test("update_system_prompt says every section is a proposal")
  func updateSystemPromptDescribesProposals() throws {
    let description = try #require(
      MCPConfigTools.writeToolDefinitions.first { $0["name"] as? String == "update_system_prompt" }?["description"] as? String)
    #expect(!description.contains("follow the user's access level"))
    #expect(description.contains("at every access level"))
  }

  @Test("The settings hint lists the sections Chat can edit")
  func chatHintFollowsEditableSections() {
    let editable = Set(ChatToolRegistry.editableInstructionSections.values)
    for section in SystemPromptSection.allCases {
      let hint = SystemPromptSectionEditor.chatEditingHint(for: section, dictationOnly: false)
      #expect((hint != nil) == editable.contains(section))
    }
    #expect(SystemPromptSectionEditor.chatEditingHint(for: .whisperGlossary, dictationOnly: true) == nil)
    #expect(SystemPromptSectionEditor.chatEditingHint(for: .dictationAdditions, dictationOnly: true) == nil)
    let prose = SystemPromptSectionEditor.chatEditingHint(for: .chat, dictationOnly: false)
    #expect(prose?.contains("dictation") == true)
    #expect(prose?.contains("Dictate Prompt") == true)
    #expect(prose?.contains("glossary") == true)
  }
}
