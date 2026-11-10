import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Dictate Prompt quick actions")
struct QuickActionStoreTests {

  @Test("Fillers, case, and edge punctuation group into one instruction; display keeps the most common spelling")
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

    let spelled = QuickActionStore.ranked(
      from: [
        "Ähm, korrigiere.",
        "Ähm, korrigiere.",
        "korrigiere",
      ],
      forceFallback: false)
    #expect(spelled[0].text == "Ähm, korrigiere")
    #expect(spelled[0].key == "korrigiere")
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
      ("formuliere neu kürzer", .shorten),
      ("make it shorter", .shorten),
      ("translat", .translate),
      ("translate to english", .translate),
      ("format as a to-do", .format),
      ("formatiere neu", .format),
      ("fix grammar and spelling", .correct),
      ("rewrite", .rewrite),
      ("formuliere neu", .rewrite),
      ("rewrite more clearly", .rewrite),
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
    #expect(actions.map(\.text) == ["Alpha one", "Write a haiku", "Beta two"])
    #expect(actions.count == QuickActionStore.cardEntries)
    #expect(QuickActionStore.fallbackTexts.allSatisfy { fallback in
      actions.contains { $0.text == fallback } == false
    })
  }

  @Test("More than nine custom prompts never reach the card, even the most used one")
  func capsCustomAtNine() {
    let texts = (1...12).map { "Prompt \($0)" }
    let counts = [
      QuickActionStore.normalizeKey("Prompt 12"): 100,
      QuickActionStore.normalizeKey("Prompt 9"): 50,
    ]
    let actions = QuickActionStore.combined(
      custom: texts,
      learned: [QuickAction(key: "extra learned", text: "Extra learned")],
      forceFallback: true,
      includeLearned: true,
      counts: counts)
    #expect(actions.count == QuickActionStore.cardEntries)
    #expect(actions.map(\.text) == ["Prompt 9", "Prompt 1", "Prompt 2"])
    #expect(actions.contains { $0.text == "Prompt 12" } == false)
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

  @Test("The card lists recent instructions first, then ranked ones, three in all")
  func cardListsRecentFirst() {
    let ranked = QuickActionStore.ranked(from: [], forceFallback: true)
    let card = QuickActionStore.cardList(recent: ["Übersetze ins Englische", "make it shorter."], ranked: ranked)
    #expect(card.count == QuickActionStore.cardEntries)
    #expect(card.map(\.text).prefix(2) == ["Übersetze ins Englische", "Make it shorter"])
    // A recent text that also ranks keeps the ranked entry, so a built-in stays an edit.
    #expect(card[1].isBuiltIn)
    #expect(card[2].text == "Fix grammar and spelling")
  }

  @Test("With own prompts the card keeps their order and highlights the last one where it stands")
  func cardKeepsOwnOrder() {
    let custom = ["Korrigiere, formuliere neu.", "Korrigiere nur Rechtschreibung", "Kürzer", "Weicher"]
    let ranked = QuickActionStore.combined(
      custom: custom, learned: [], forceFallback: false, includeLearned: true)
    let card = QuickActionStore.card(
      custom: custom, recent: ["kürzer", "Korrigiere, formuliere neu."], ranked: ranked,
      preselect: true)
    #expect(card.actions.map(\.text) == Array(custom.prefix(QuickActionStore.cardEntries)))
    #expect(card.preselectIndex == 2)
  }

  @Test("With own prompts nothing is highlighted when the last run was spoken or typed elsewhere")
  func cardOwnPromptsNoPreselect() {
    let custom = ["Korrigiere", "Kürzer"]
    let ranked = QuickActionStore.combined(
      custom: custom, learned: [], forceFallback: false, includeLearned: true)
    #expect(
      QuickActionStore.card(custom: custom, recent: ["Kürzer"], ranked: ranked, preselect: false)
        .preselectIndex == nil)
    #expect(
      QuickActionStore.card(custom: custom, recent: ["Übersetze"], ranked: ranked, preselect: true)
        .preselectIndex == nil)
  }

  @Test("Without own prompts the card stays recent-first, three entries, first highlighted")
  func cardWithoutOwnPrompts() {
    let ranked = QuickActionStore.ranked(from: [], forceFallback: true)
    let card = QuickActionStore.card(
      custom: [" "], recent: ["Übersetze ins Englische"], ranked: ranked, preselect: true)
    #expect(card.actions.count == QuickActionStore.cardEntries)
    #expect(card.actions.first?.text == "Übersetze ins Englische")
    #expect(card.preselectIndex == 0)
  }

  @Test("Recording a use moves it to the front, drops its duplicate, keeps three")
  func updatedRecentMovesToFront() {
    let recent = ["Korrigiere", "Formuliere neu", "Formatiere neu"]
    #expect(
      QuickActionStore.updatedRecent(recent, using: " formuliere neu. ")
        == ["formuliere neu.", "Korrigiere", "Formatiere neu"])
    #expect(
      QuickActionStore.updatedRecent(recent, using: "Kürzer")
        == ["Kürzer", "Korrigiere", "Formuliere neu"])
    let long = String(repeating: "word ", count: 20)
    #expect(QuickActionStore.updatedRecent(recent, using: long) == recent)
  }

  @Test("The most-used own prompt leads the card")
  func countsReorderOwnPrompts() {
    let actions = QuickActionStore.combined(
      custom: ["Alpha", "Beta", "Gamma"],
      learned: [],
      forceFallback: false,
      includeLearned: true,
      counts: ["gamma": 5])
    #expect(actions.map(\.text) == ["Gamma", "Alpha", "Beta"])
  }

  @Test("A more-used learned prompt leads and the least-used own prompt drops off")
  func learnedUsePushesUnusedOwnOffCard() {
    let learnedText = "Übersetze ins Englische"
    let learnedKey = QuickActionStore.normalizeKey(learnedText)
    let actions = QuickActionStore.combined(
      custom: ["A", "B", "C"],
      learned: [QuickAction(key: learnedKey, text: learnedText)],
      forceFallback: false,
      includeLearned: true,
      counts: [learnedKey: 4])
    #expect(actions.map(\.text) == ["Übersetze ins Englische", "A", "B"])
  }

  @Test("A learned prompt whose kind matches an earlier entry is left off the card")
  func learnedSameKindIsSkipped() {
    let own = "Korrigiere, formuliere neu."
    let redundant = "Korrigiere nur Rechtschreibung"
    let other = "Übersetze ins Englische"
    let actions = QuickActionStore.combined(
      custom: [own],
      learned: [
        QuickAction(key: QuickActionStore.normalizeKey(redundant), text: redundant),
        QuickAction(key: QuickActionStore.normalizeKey(other), text: other),
      ],
      forceFallback: false,
      includeLearned: true,
      counts: [
        QuickActionStore.normalizeKey(own): 3,
        QuickActionStore.normalizeKey(redundant): 2,
        QuickActionStore.normalizeKey(other): 1,
      ])
    #expect(actions.map(\.text) == [own, other])
  }

  @Test("With own prompts the card never grows past three")
  func combinedNeverExceedsCardEntries() {
    let texts = (1...8).map { "Prompt \($0)" }
    let learned = (1...5).map { QuickAction(key: "learned \($0)", text: "Learned \($0)") }
    var counts: [String: Int] = [:]
    for text in texts { counts[QuickActionStore.normalizeKey(text)] = 3 }
    for action in learned { counts[action.key] = 9 }
    let actions = QuickActionStore.combined(
      custom: texts, learned: learned, forceFallback: false, includeLearned: true, counts: counts)
    #expect(actions.count == QuickActionStore.cardEntries)
    let ownOnly = QuickActionStore.combined(
      custom: texts, learned: learned, forceFallback: false, includeLearned: false, counts: counts)
    #expect(ownOnly.count == QuickActionStore.cardEntries)
    #expect(ownOnly.map(\.text) == Array(texts.prefix(QuickActionStore.cardEntries)))
  }

  @Test("Usage counts group by normalized key and keep a single use")
  func usageCountsGroupsNormalizedKeys() {
    let placeholder = SpeechService.voiceInstructionPlaceholder
    let long = String(repeating: "a", count: 61)
    let counts = QuickActionStore.usageCounts(from: [
      "Kürzer.",
      "kürzer",
      placeholder,
      "only once",
      long,
      "",
      "   ",
    ])
    #expect(counts["kürzer"] == 2)
    #expect(counts["only once"] == 1)
    #expect(counts[long] == 1)
    #expect(counts[QuickActionStore.normalizeKey(placeholder)] == nil)
    #expect(counts.count == 3)
  }
}
