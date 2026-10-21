import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Smart Improvement may only append to the Whisper Glossary, and near-miss mining has to
/// propose real mishearings without dragging in dictionary words, plurals, or a second
/// glossary entry. These lock that contract; a rewrite that "cleans up" the glossary fails them.
@Suite("Glossary learning")
struct GlossaryLearningTests {

  private static let fixture = """
  Christoph Michelbach (not "m1cm1")
  sabaki.dance (not "Bachi dance")
  Wianco (not "Vianco")
  Terms: GrokBot, Smikale, Cursor, EnBW, Fable, Sonnet
  """

  @Test("A suggestion adds only new terms and leaves every current line in place")
  func mergeNeverDropsAnEntry() {
    let result = GlossaryLearning.mergeAdditively(
      current: Self.fixture, suggestion: "Terms: Bachata, Cursor, Gemini")
    #expect(result.hasPrefix(Self.fixture))
    for line in Self.fixture.components(separatedBy: .newlines) where !line.isEmpty {
      #expect(result.contains(line))
    }
    #expect(result == Self.fixture + "\nBachata\nGemini")
  }

  @Test("A suggestion that lists only one new term still keeps the whole glossary")
  func suggestionThatDropsEverythingStillKeepsCurrent() {
    let result = GlossaryLearning.mergeAdditively(current: Self.fixture, suggestion: "Terms: Gemini")
    #expect(result.hasPrefix(Self.fixture))
    #expect(result.contains("Christoph Michelbach (not \"m1cm1\")"))
    #expect(result.contains("sabaki.dance (not \"Bachi dance\")"))
    #expect(result.contains("Wianco (not \"Vianco\")"))
    #expect(result.contains("Terms: GrokBot, Smikale, Cursor, EnBW, Fable, Sonnet"))
    #expect(result == Self.fixture + "\nGemini")
  }

  @Test("A rejected spelling is not added back as its own term")
  func rejectedFormIsNotReadded() {
    let result = GlossaryLearning.mergeAdditively(current: Self.fixture, suggestion: "Terms: Vianco")
    #expect(result == Self.fixture)
  }

  @Test("Case and diacritics do not create a second copy of a term")
  func caseAndDiacriticsCollapse() {
    #expect(GlossaryLearning.mergeAdditively(current: Self.fixture, suggestion: "Terms: cursor, ENBW") == Self.fixture)
    #expect(GlossaryLearning.mergeAdditively(current: "Gödde", suggestion: "gödde") == "Gödde")
    // ö folds away, so the unaccented spelling is the same term the user already wrote.
    #expect(GlossaryLearning.mergeAdditively(current: "Gödde", suggestion: "Godde") == "Gödde")
  }

  @Test("An annotated line is appended, and a known term only gains new rejected spellings")
  func annotatedSuggestionsAppendOnlyWhatIsNew() {
    let added = GlossaryLearning.mergeAdditively(
      current: Self.fixture, suggestion: "Gemini (not \"Geminni\")")
    #expect(added == Self.fixture + "\nGemini (not \"Geminni\")")

    let extended = GlossaryLearning.mergeAdditively(
      current: Self.fixture, suggestion: "Wianco (not \"Vianco\", \"Viancko\")")
    #expect(extended == Self.fixture + "\nWianco (not \"Viancko\")")
  }

  @Test("An empty glossary is just the additions")
  func emptyCurrentIsJustAdditions() {
    #expect(GlossaryLearning.mergeAdditively(current: "", suggestion: "Terms: Gemini, Cursor") == "Gemini\nCursor")
    #expect(GlossaryLearning.mergeAdditively(current: "\n\n", suggestion: "Bachata") == "Bachata")
  }

  @Test("Frequent mishearings of one term are proposed, a one-off is not")
  func nearMissMinesRepeatedVariantsOnly() {
    // Two short fillers keep Bachata under the ambient-doc cutoff (half the corpus). Without
    // them six Bachata transcripts out of eleven would look like a function word and be dropped.
    let transcripts = [
      "Heute Bachata Kurs",
      "Bachata Party am Freitag",
      "Wir tanzen Bachata",
      "Bachata Musik ist gut",
      "Morgen Bachata Training",
      "Die Bachata Stunde",
      "Batchata Kurs heute",
      "Ich mag Batchata",
      "Bachatta Festival",
      "Bachatta Abend",
      "Bachada Versuch",
      "Ok",
      "Ja",
      "Hi",
      "Yo",
    ]
    let misses = GlossaryLearning.nearMisses(glossary: "", transcripts: transcripts)
    #expect(misses == [GlossaryLearning.NearMiss(term: "Bachata", variants: ["Bachatta", "Batchata"])])
  }

  @Test("A lowercase glossary term is shown with the corpus's majority capitalisation")
  func nearMissUsesMajorityCapitalisation() {
    let transcripts = [
      "Bachata eins", "Bachata zwei", "Bachata drei", "Bachata vier",
      "Batchata eins", "Batchata zwei",
    ]
    let misses = GlossaryLearning.nearMisses(glossary: "bachata", transcripts: transcripts)
    #expect(misses == [GlossaryLearning.NearMiss(term: "Bachata", variants: ["Batchata"])])
  }

  @Test("Two similar names used about equally often are not a mishearing of each other")
  func comparablyFrequentNamesAreNotNearMisses() {
    // Neither name is in the glossary, so the corpus has to show one form clearly dominating.
    // Martin 6 vs Marvin 3 is two people, not a recognizer error (a mishearing is the rare form).
    let transcripts = repeated("Martin", count: 6) + repeated("Marvin", count: 3)
      + (0..<10).map { "filler \($0)" }
    #expect(GlossaryLearning.nearMisses(glossary: "", transcripts: transcripts).isEmpty)
  }

  @Test("Dictionary near-misses and four-letter words are not glossary candidates")
  func commonWordsAreNotNearMisses() {
    let known: (String) -> Bool = { ["Hallo", "Halle", "Sonne", "Sonnet", "Haus", "Maus"].contains($0) }
    // Hallo/Sonne outnumber their one-edit neighbours three to one, so the frequency check
    // would still accept the pair; only the dictionary guard may reject it. The terms occur
    // often enough, with a capital initial, that none of them fail the shape filters.
    let transcripts =
      repeated("Hallo", count: 9) + repeated("Halle", count: 3)
      + repeated("Sonne", count: 9) + repeated("Sonnet", count: 3)
      + repeated("Haus", count: 9) + repeated("Maus", count: 3)
    #expect(GlossaryLearning.nearMisses(glossary: "", transcripts: transcripts, isKnownWord: known).isEmpty)

    let unguarded = GlossaryLearning.nearMisses(glossary: "", transcripts: transcripts, isKnownWord: { _ in false })
    #expect(unguarded.contains { $0.term == "Hallo" && $0.variants.contains("Halle") })
    #expect(unguarded.contains { $0.term == "Sonne" && $0.variants.contains("Sonnet") })
  }

  @Test("Words shorter than five letters never become near-miss candidates")
  func fourLetterWordsNeverQualify() {
    // Same first letter and one edit apart, with unequal counts, so the only thing that
    // keeps this pair out is the five-letter floor. Fillers hold the ambient cutoff above
    // Haus's doc frequency; otherwise the pair would be dropped for the wrong reason.
    let transcripts = repeated("Haus", count: 6) + repeated("Haut", count: 2) + repeated("Zz", count: 6)
    let misses = GlossaryLearning.nearMisses(glossary: "", transcripts: transcripts, isKnownWord: { _ in false })
    #expect(misses.isEmpty)
  }

  @Test("A plural ending is not a mishearing")
  func inflectionIsNotANearMiss() {
    let transcripts = repeated("Workshop", count: 5) + repeated("Workshops", count: 2) + repeated("Zz", count: 6)
    let misses = GlossaryLearning.nearMisses(glossary: "", transcripts: transcripts)
    #expect(misses.isEmpty)
  }

  @Test("A variant that is itself a glossary term is not proposed")
  func glossaryTermIsNotAVariantOfAnother() {
    let transcripts = [
      "Gemini eins", "Gemini zwei",
      "Gemina eins", "Gemina zwei",
    ]
    let misses = GlossaryLearning.nearMisses(glossary: "Gemini\nGemina", transcripts: transcripts)
    #expect(misses.isEmpty)
  }

  @Test("Majority casing rewrites new lines and leaves asserted lines and rejected spellings alone")
  func majorityCasingRespectsCurrentLinesAndAnnotations() {
    let few = ["Bachata", "Bachata"]
    #expect(GlossaryLearning.applyingMajorityCasing(to: "bachata", keepingLinesOf: "", transcripts: few) == "bachata")

    let transcripts = ["Bachata", "Bachata", "Bachata"]
    #expect(GlossaryLearning.applyingMajorityCasing(to: "bachata", keepingLinesOf: "", transcripts: transcripts) == "Bachata")
    #expect(GlossaryLearning.applyingMajorityCasing(to: "bachata", keepingLinesOf: "bachata", transcripts: transcripts) == "bachata")
    #expect(
      GlossaryLearning.applyingMajorityCasing(
        to: "bachata\nextra bachata",
        keepingLinesOf: "bachata",
        transcripts: transcripts) == "bachata\nextra Bachata")
    #expect(
      GlossaryLearning.applyingMajorityCasing(
        to: "bachata (not \"bachata\")",
        keepingLinesOf: "",
        transcripts: transcripts) == "Bachata (not \"bachata\")")
    #expect(
      GlossaryLearning.applyingMajorityCasing(
        to: "bachata (nicht \"bachata\")",
        keepingLinesOf: "",
        transcripts: transcripts) == "Bachata (nicht \"bachata\")")
  }

  @Test("Near-miss lines use the annotated glossary shape")
  func nearMissLinesUseAnnotatedShape() {
    let lines = GlossaryLearning.nearMissLines([
      GlossaryLearning.NearMiss(term: "Bachata", variants: ["Bachatta", "Batchata"])
    ])
    #expect(lines == "Bachata (not \"Bachatta\", \"Batchata\")")
  }

  private func repeated(_ word: String, count: Int) -> [String] {
    (0..<count).map { "\(word) \($0)" }
  }

  // MARK: - Applying a reviewed glossary

  @Test("Unchanged glossary: the accepted text is written as is, deletions included")
  func reviewedGlossaryHonoursDeletions() {
    let original = "Alpha\nBeta\nGamma"
    let accepted = "Alpha\nGamma"
    let result = AutoPromptImprovementScheduler.glossaryToApply(
      current: original, panelOriginal: original, accepted: accepted)
    #expect(result == accepted)
  }

  @Test("Lines appended while the panel was open are kept, user deletions stay deleted")
  func reviewedGlossaryKeepsLateAppends() {
    let original = "Alpha\nBeta\nGamma"
    let current = original + "\nDelta"
    let accepted = "Alpha\nGamma"
    let result = AutoPromptImprovementScheduler.glossaryToApply(
      current: current, panelOriginal: original, accepted: accepted)
    #expect(result.contains("Delta"))
    #expect(!result.contains("Beta"))
  }
}
