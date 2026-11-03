import Foundation

/// Filters FluidAudio CTC vocabulary replacements before they rewrite a transcript.
///
/// The booster is allowed to correct a misspelt glossary term. It is not allowed to
/// delete a lab value sitting next to one ("HbA1c 7,2" → "HbA1c"), swap one glossary
/// drug for another ("Bisoprolol" → "Metoprolol"), or swallow a neighbouring drug
/// ("weiter Bisoprolol" → "Metoprolol"). Those showed up on clean speech in
/// `benchmarks/parakeet-glossary-casing` and are worse than leaving the misspelling.
enum ParakeetVocabularyGuard {
  struct Replacement: Equatable {
    let originalSpan: String
    let term: String
  }

  /// Accepted only if all of these hold:
  /// (a) every digit run in the span also occurs among the term's digit runs
  ///     ("B 12" → "B12" passes, "HbA1c 7,2" → "HbA1c" does not),
  /// (b) neither the whole span nor any single word of it (whitespace-split,
  ///     punctuation stripped, compared via `GlossaryDocument.fold`) is a glossary
  ///     term other than the replacement ("weiter Bisoprolol" → "Metoprolol" fails),
  /// (c) the span has no more words than the term plus one.
  static func accepts(_ replacement: Replacement, glossaryTerms: [String]) -> Bool {
    let original = replacement.originalSpan
    let term = replacement.term

    let termRuns = Set(digitRuns(term))
    if digitRuns(original).contains(where: { !termRuns.contains($0) }) { return false }

    let foldedTerm = GlossaryDocument.fold(term)
    let foldedOtherTerms = Set(
      glossaryTerms.map { GlossaryDocument.fold($0) }.filter { $0 != foldedTerm })
    if foldedOtherTerms.contains(GlossaryDocument.fold(original)) { return false }
    for word in original.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
      let stripped = word.trimmingCharacters(in: .punctuationCharacters)
      if !stripped.isEmpty, foldedOtherTerms.contains(GlossaryDocument.fold(stripped)) {
        return false
      }
    }

    if wordCount(original) > wordCount(term) + 1 { return false }
    return true
  }

  /// Applies only the accepted replacements to `original` (never FluidAudio's
  /// already-rewritten `rescored.text`). First occurrence of each span that is not
  /// glued to a letter or digit on either side, in order.
  static func apply(
    to original: String,
    replacements: [Replacement],
    glossaryTerms: [String]
  ) -> (text: String, accepted: Int, rejected: Int) {
    var text = original
    var accepted = 0
    var rejected = 0
    for replacement in replacements {
      guard accepts(replacement, glossaryTerms: glossaryTerms) else {
        rejected += 1
        continue
      }
      guard let range = firstBoundedRange(of: replacement.originalSpan, in: text) else {
        rejected += 1
        continue
      }
      text.replaceSubrange(range, with: replacement.term)
      accepted += 1
    }
    return (text, accepted, rejected)
  }

  /// First match whose neighbouring characters are not letters or digits.
  private static func firstBoundedRange(of span: String, in text: String) -> Range<String.Index>? {
    guard !span.isEmpty else { return nil }
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
      let range = text.range(of: span, range: searchStart..<text.endIndex)
    {
      let beforeOK = range.lowerBound == text.startIndex
        || !isWordCharacter(text[text.index(before: range.lowerBound)])
      let afterOK = range.upperBound == text.endIndex
        || !isWordCharacter(text[range.upperBound])
      if beforeOK && afterOK { return range }
      searchStart = text.index(after: range.lowerBound)
    }
    return nil
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
  }

  /// Maximal runs of digits, e.g. "HbA1c 7,2" → ["1", "7", "2"].
  private static func digitRuns(_ text: String) -> [String] {
    var runs: [String] = []
    var current = ""
    for character in text {
      if character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        runs.append(current)
        current = ""
      }
    }
    if !current.isEmpty { runs.append(current) }
    return runs
  }

  private static func wordCount(_ text: String) -> Int {
    text.split { $0.isWhitespace || $0.isNewline }.count
  }
}
