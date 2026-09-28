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
}
