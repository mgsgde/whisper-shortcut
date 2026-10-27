import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Dictate Prompt quick actions")
struct QuickActionStoreTests {

  @Test("Fillers, case, and edge punctuation group into one instruction")
  func normalizationGroupsRepeatedPrompts() {
    let actions = QuickActionStore.ranked(
      from: [
        "  Ähm, korrigiere! ",
        "korrigiere",
        "Korrigiere.",
        "Korrigiere.",
      ],
      forceFallback: false)
    #expect(actions.count == 5)
    #expect(actions[0].key == "korrigiere")
    #expect(actions[0].text == "Korrigiere")
  }

  @Test("Only built-in defaults count as edit actions, not user prompts that match a keyword")
  func onlyBuiltInDefaultsAreEdits() {
    let custom = QuickActionStore.combined(
      custom: ["Write a short reply", "Draft a todo list"], learned: [],
      forceFallback: false, includeLearned: true)
    #expect(custom.count == 2)
    let customKeywordNonEdits = custom.allSatisfy { $0.kind != .other && !$0.isEdit }
    #expect(customKeywordNonEdits)

    let builtIn = QuickActionStore.ranked(from: [], forceFallback: true)
    #expect(builtIn.map(\.text) == QuickActionStore.fallbackTexts)
    let builtInAreEdits = builtIn.allSatisfy { $0.isEdit }
    #expect(builtInAreEdits)

    let bareVerb = QuickActionStore.combined(
      custom: ["Korrigiere"], learned: [], forceFallback: false, includeLearned: true)
    #expect(bareVerb.first?.isEdit == true)
  }

  @Test("Display text keeps the most common original spelling")
  func displayUsesMostFrequentSpelling() {
    let actions = QuickActionStore.ranked(
      from: [
        "Ähm, korrigiere.",
        "Ähm, korrigiere.",
        "korrigiere",
      ],
      forceFallback: false)
    #expect(actions[0].text == "Ähm, korrigiere")
    #expect(actions[0].key == "korrigiere")
  }

  @Test("A single use, the voice placeholder, and long one-offs are skipped")
  func skipsNoise() {
    let placeholder = SpeechService.voiceInstructionPlaceholder
    let long = String(repeating: "a", count: 61)
    let actions = QuickActionStore.ranked(
      from: [
        "only once",
        placeholder,
        placeholder,
        long,
        long,
        "ähm um uh",
        "ähm um uh",
      ],
      forceFallback: false)
    #expect(actions.map(\.text) == QuickActionStore.fallbackTexts)
  }

  @Test("Three learned instructions are not padded")
  func threeLearnedSkipDefaults() {
    let actions = QuickActionStore.ranked(
      from: repeated("Alpha one", "Beta two", "Gamma three"),
      forceFallback: false)
    #expect(actions.map(\.text) == ["Alpha one", "Beta two", "Gamma three"])
  }

  @Test("Logging disabled still fills the list after learned entries")
  func fallbackKeepsLearnedFirst() {
    let actions = QuickActionStore.ranked(
      from: repeated("Alpha one", "Beta two", "Gamma three"),
      forceFallback: true)
    #expect(actions.count == 5)
    #expect(actions.prefix(3).map(\.text) == ["Alpha one", "Beta two", "Gamma three"])
    #expect(actions.dropFirst(3).map(\.text) == ["Fix grammar and spelling", "Rewrite more clearly"])
  }

  @Test("A learned default is not repeated when the list is padded")
  func paddingSkipsDuplicateDefaults() {
    let actions = QuickActionStore.ranked(
      from: ["Fix grammar and spelling", "Fix grammar and spelling"],
      forceFallback: false)
    #expect(actions.map(\.text).filter { $0 == "Fix grammar and spelling" }.count == 1)
    #expect(actions.count == 5)
    #expect(actions[0].text == "Fix grammar and spelling")
  }

  @Test("Only the five most common instructions are kept")
  func capsAtFive() {
    let actions = QuickActionStore.ranked(
      from: repeated("Group a", "Group b", "Group c", "Group d", "Group e", "Group f"),
      forceFallback: false)
    #expect(actions.map(\.text) == ["Group a", "Group b", "Group c", "Group d", "Group e"])
  }

  @Test("Filler tokens are whole words, and a 60-character key still qualifies")
  func fillerAndLengthBoundaries() {
    let sixty = String(repeating: "b", count: 60)
    let actions = QuickActionStore.ranked(
      from: [sixty, sixty, "umbrella please", "umbrella please"],
      forceFallback: false)
    #expect(actions.count == 5)
    #expect(actions[0].key == sixty)
    #expect(actions[0].text == "B" + String(repeating: "b", count: 59))
    #expect(actions[1].key == "umbrella please")
  }

  private func repeated(_ texts: String...) -> [String] {
    texts.flatMap { [$0, $0] }
  }

  // MARK: - QuickActionKind.classify

  @Test(
    "Classification matches intent, with order resolving overlaps",
    arguments: [
      ("kürz", QuickActionKind.shorten),
      ("kurz", .shorten),
      ("short", .shorten),
      ("concise", .shorten),
      ("condense", .shorten),
      ("raccourc", .shorten),
      ("acorta", .shorten),
      ("formuliere neu kürzer", .shorten),
      ("übersetz", .translate),
      ("translat", .translate),
      ("tradui", .translate),
      ("tradu", .translate),
      ("format", .format),
      ("to-do", .format),
      ("todo", .format),
      ("bullet", .format),
      ("aufzähl", .format),
      ("markdown", .format),
      ("tabelle", .format),
      ("table", .format),
      ("formatiere neu", .format),
      ("korrig", .correct),
      ("corrig", .correct),
      ("correct", .correct),
      ("fix", .correct),
      ("grammat", .correct),
      ("grammar", .correct),
      ("rechtschreib", .correct),
      ("spelling", .correct),
      ("tippfehler", .correct),
      ("typo", .correct),
      ("proofread", .correct),
      ("fix grammar and spelling", .correct),
      ("formulier", .rewrite),
      ("rewrite", .rewrite),
      ("rephrase", .rewrite),
      ("reword", .rewrite),
      ("umschreib", .rewrite),
      ("reformul", .rewrite),
      ("klarer", .rewrite),
      ("clearer", .rewrite),
      ("formuliere neu", .rewrite),
      ("rewrite more clearly", .rewrite),
      ("format as a to-do", .format),
      ("translate to english", .translate),
      ("make it shorter", .shorten),
      ("mach eine mail draus", .other),
    ])
  func classify(_ pair: (key: String, expected: QuickActionKind)) {
    #expect(QuickActionKind.classify(pair.key) == pair.expected)
  }

  @Test("Same-language-pair intent merges, keeping the more frequent spelling")
  func crossLanguageDuplicatesMerge() {
    let actions = QuickActionStore.ranked(
      from: repeated("Korrigiere", "Korrigiere", "Korrigiere", "Korrigiere")
        + repeated("Corriger", "Corriger"),
      forceFallback: false)
    let correctEntries = actions.filter { $0.kind == .correct }
    #expect(correctEntries.count == 1)
    #expect(correctEntries.first?.text == "Korrigiere")
    #expect(actions.contains { $0.text == "Corriger" } == false)
  }

  @Test("Multi-word entries of the same kind both survive de-duplication")
  func multiWordEntriesOfSameKindBothKept() {
    let actions = QuickActionStore.ranked(
      from: repeated("Formuliere neu", "Formuliere neu kürzer"),
      forceFallback: false)
    #expect(actions.contains { $0.text == "Formuliere neu" })
    #expect(actions.contains { $0.text == "Formuliere neu kürzer" })
  }

  @Test("Padding skips a fallback whose kind a learned entry already covers")
  func paddingSkipsFallbackOfSameKind() {
    let actions = QuickActionStore.ranked(
      from: repeated("Korrigiere", "Korrigiere"),
      forceFallback: false)
    #expect(actions.contains { $0.text == "Fix grammar and spelling" } == false)
    #expect(actions.contains { $0.text == "Korrigiere" })
  }

  // MARK: - Custom prompts

  @Test("Custom prompts alone stay in order, trimmed, without blanks or duplicate keys")
  func customOnlyDropsBlanksAndDuplicates() {
    let actions = QuickActionStore.combined(
      custom: ["  First prompt  ", "", "   ", "ähm", "First prompt.", "Second prompt"],
      learned: [QuickAction(key: "ignored", text: "Ignored")],
      forceFallback: true,
      includeLearned: false)
    #expect(actions.map(\.text) == ["First prompt", "Second prompt"])
  }

  @Test("Custom prompts come first; a learned duplicate and the built-in defaults are left out")
  func customThenLearnedSkipsDuplicateAndDefaults() {
    let learned = [
      QuickAction(key: "alpha one", text: "Alpha one"),
      QuickAction(key: "beta two", text: "Beta two"),
      QuickAction(key: "gamma three", text: "Gamma three"),
    ]
    let actions = QuickActionStore.combined(
      custom: ["  Alpha one  ", "Write a haiku"],
      learned: learned,
      forceFallback: true,
      includeLearned: true)
    #expect(actions.map(\.text) == ["Alpha one", "Write a haiku", "Beta two", "Gamma three"])
    #expect(QuickActionStore.fallbackTexts.allSatisfy { fallback in
      actions.contains { $0.text == fallback } == false
    })
  }

  @Test("More than nine custom prompts are capped at nine")
  func capsCustomAtNine() {
    let texts = (1...12).map { "Prompt \($0)" }
    let actions = QuickActionStore.combined(
      custom: texts,
      learned: [QuickAction(key: "extra learned", text: "Extra learned")],
      forceFallback: true,
      includeLearned: true)
    #expect(actions.count == 9)
    #expect(actions.map(\.text) == Array(texts.prefix(9)))
  }

  @Test("With no custom prompts, learning on matches the ranked list")
  func noCustomMatchesRanked() {
    let many = repeated("Alpha one", "Beta two", "Gamma three")
    let learnedMany = QuickActionStore.ranked(from: many, forceFallback: false)
    #expect(learnedMany.count >= 3)
    #expect(
      QuickActionStore.combined(
        custom: [], learned: learnedMany, forceFallback: false, includeLearned: true)
      == QuickActionStore.ranked(from: many, forceFallback: false))
    #expect(
      QuickActionStore.combined(
        custom: [], learned: learnedMany, forceFallback: true, includeLearned: true)
      == QuickActionStore.ranked(from: many, forceFallback: true))

    let few = repeated("Alpha one")
    let learnedFew = QuickActionStore.rankLearned(from: few)
    #expect(learnedFew.count < 3)
    let padded = QuickActionStore.combined(
      custom: [], learned: learnedFew, forceFallback: false, includeLearned: true)
    #expect(padded == QuickActionStore.ranked(from: few, forceFallback: false))
    #expect(padded.count == QuickActionStore.maxEntries)
    #expect(padded.map(\.text).first == "Alpha one")
    #expect(padded.map(\.text).contains("Fix grammar and spelling"))
  }

  @Test("With no custom prompts, learning off leaves the list empty")
  func noCustomLearningOffIsEmpty() {
    let learned = QuickActionStore.ranked(
      from: repeated("Alpha one", "Beta two", "Gamma three"),
      forceFallback: false)
    let actions = QuickActionStore.combined(
      custom: ["", "   "],
      learned: learned,
      forceFallback: true,
      includeLearned: false)
    #expect(actions.isEmpty)
  }

  @Test("Custom prompt text keeps the spelling the user typed")
  func customKeepsTypedSpelling() {
    let actions = QuickActionStore.combined(
      custom: ["  translate to German.  "],
      learned: [],
      forceFallback: true,
      includeLearned: true)
    #expect(actions.map(\.text) == ["translate to German."])
  }
}
