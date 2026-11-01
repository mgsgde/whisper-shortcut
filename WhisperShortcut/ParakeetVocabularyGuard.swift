import Foundation

/// Filters FluidAudio CTC vocabulary replacements before they rewrite a transcript.
///
/// The booster is allowed to correct a misspelt glossary term. It is not allowed to
/// delete a lab value sitting next to one ("HbA1c 7,2" → "HbA1c"), swap one glossary
/// drug for another ("Bisoprolol" → "Metoprolol"), or swallow a neighbouring word
/// ("weiter Bisoprolol" → "Metoprolol"). Those showed up on clean speech in
/// `benchmarks/parakeet-glossary-casing` and are worse than leaving the misspelling.
enum ParakeetVocabularyGuard {
  struct Replacement: Equatable {
    let originalSpan: String
    let term: String
  }

  /// (a) no digit in the original span, (b) the span is not itself a different
  /// glossary term, (c) the span has no more words than the term plus one.
  static func accepts(_ replacement: Replacement, glossaryTerms: [String]) -> Bool {
    let original = replacement.originalSpan
    let term = replacement.term
    if original.contains(where: \.isNumber) { return false }

    let foldedOriginal = GlossaryDocument.fold(original)
    let foldedTerm = GlossaryDocument.fold(term)
    if foldedOriginal != foldedTerm,
      glossaryTerms.contains(where: { GlossaryDocument.fold($0) == foldedOriginal })
    {
      return false
    }

    if wordCount(original) > wordCount(term) + 1 { return false }
    return true
  }

  /// Applies only the accepted replacements to `original` (never FluidAudio's
  /// already-rewritten `rescored.text`). First occurrence of each span, in order.
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
      guard let range = text.range(of: replacement.originalSpan) else {
        rejected += 1
        continue
      }
      text.replaceSubrange(range, with: replacement.term)
      accepted += 1
    }
    return (text, accepted, rejected)
  }

  private static func wordCount(_ text: String) -> Int {
    text.split { $0.isWhitespace || $0.isNewline }.count
  }
}
