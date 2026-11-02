import Foundation

/// Turns spoken layout commands into layout in offline transcripts.
///
/// Parakeet and local Whisper write a spoken "Doppelpunkt" or "neuer Absatz" out as words
/// ("Anamnese Doppelpunkt Patient berichtet …"), where cloud models that take a dictation prompt
/// already produce the punctuation. This is the deterministic fix for the offline engines only.
///
/// Deliberately narrow: "Punkt", "Komma" and "Fragezeichen" are ordinary German words ("der
/// wichtigste Punkt"), so they are left alone. Only phrases that are almost never meant literally in
/// dictation are converted, matched case-insensitively on whole words. The exception is the
/// "Only when spoken" punctuation mode (`PunctuationMode.spokenOnly`): there the user has opted in
/// to saying the marks, so "Punkt", "Komma", "Fragezeichen" and "Ausrufezeichen" are converted too.
enum SpokenPunctuation {
  private struct Rule {
    let regex: NSRegularExpression
    let template: String
  }

  /// Order matters: the colon runs first so "Befund Doppelpunkt neuer Absatz" keeps its colon when
  /// the paragraph rule then strips the stray space before the break.
  private static let rules: [Rule] = [
    // The colon is already there — a model reply that kept the spoken word after its own heading
    // ("Befund: Doppelpunkt Druckschmerz", "Anamnese:\nDoppelpunkt Patientin"). Drop the word only.
    rule(#"(:[ \t]*\n?[ \t]*)\bdoppelpunkt\b[ \t,.;:]*"#, "$1"),
    // "Anamnese Doppelpunkt Patient" / "Befund, Doppelpunkt. Inspektion" → "Befund: Inspektion".
    // Eats the punctuation the ASR put around the word on both sides.
    rule(#"[ \t,.;]*\bdoppelpunkt\b[ \t,.;:]*"#, ": "),
    // Parakeet sometimes glues the command onto the next word ("Befund Doppelpunktdruckschmerz").
    // The following word's first letter is upper-cased afterwards (`capitalizeAfterGluedColon`).
    // Inflections of the noun itself ("Doppelpunkte", "-en", "-es", "-s") are left alone.
    rule(#"[ \t,.;]*\bdoppelpunkt(?!(?:e|en|es|s)\b)(?=\p{L})"#, ": \u{1}"),
    // A comma before a spoken paragraph break is the ASR marking the pause; the sentence ended.
    rule(#"[ \t]*,[ \t]*\bneue[rn][ \t]+absatz\b[ \t,.;:!?]*"#, ".\n\n"),
    // Paragraph break. A sentence end before it (". ! ? :") is kept, a stray comma is not.
    rule(#"[ \t,;]*\bneue[rn][ \t]+absatz\b[ \t,.;:!?]*"#, "\n\n"),
    rule(#"[ \t,;]*\bneue[ \t]+zeile\b[ \t,.;:!?]*"#, "\n"),
    // Parakeet glues this one onto the next word too ("neue Zeileinspektion", live capture
    // 2026-10-20). "neue Zeilen…" is left alone: that is the plural or a compound, said literally.
    rule(#"[ \t,;]*\bneue[ \t]+zeile(?!n)(?=\p{L})"#, "\n\u{1}"),
    // "ich Schrägstrich sage" → "ich/sage". Spaces and stray ASR commas/periods around it go.
    // "Schrägstriche" (plural) does not match; the glued form ("Schrägstrichsage") does.
    rule(#"[ \t,.;]*\bschr(?:ä|ae)gstrich\b[ \t,.;]*"#, "/"),
    rule(#"[ \t,.;]*\bschr(?:ä|ae)gstrich(?!(?:e|en|es|s)\b)(?=\p{L})"#, "/"),
  ]

  /// Only in `PunctuationMode.spokenOnly`, where the model adds no punctuation of its own. The mark
  /// attaches to the previous word with one space after; after ". ? !" the next word is
  /// capitalized (marker, see `capitalizeAfterGluedColon`). Run after `rules`.
  private static let spokenOnlyRules: [Rule] = [
    rule(#"[ \t,.;]*\bfragezeichen\b[ \t,.;]*"#, "? \u{1}"),
    rule(#"[ \t,.;]*\bausrufezeichen\b[ \t,.;]*"#, "! \u{1}"),
    rule(#"[ \t,.;]*\bpunkt\b[ \t,.;]*"#, ". \u{1}"),
    rule(#"[ \t,.;]*\bkomma\b[ \t,.;]*"#, ", "),
  ]

  /// Removes the punctuation an offline model inserted on its own (`. , ; ! ?`) for
  /// `PunctuationMode.spokenOnly`. Only marks followed by whitespace or the end of the text, so
  /// "3.5" and "1,2" survive. Run before `apply`.
  static func stripModelPunctuation(from text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    return stripRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
  }

  // swiftlint:disable:next force_try
  private static let stripRegex = try! NSRegularExpression(pattern: #"[.,;!?]+(?=\s|$)"#)

  /// The glued-command rules leave a U+0001 marker before the word they split off; this upper-cases
  /// that word's first letter ("Doppelpunktdruckschmerz" → ": Druckschmerz") and drops the marker.
  private static func capitalizeAfterGluedColon(_ text: String) -> String {
    guard text.contains("\u{1}") else { return text }
    var out = ""
    var upperNext = false
    for ch in text {
      if ch == "\u{1}" { upperNext = true; continue }
      out += upperNext ? ch.uppercased() : String(ch)
      upperNext = false
    }
    return out
  }

  private static let trailingSpaceBeforeBreak = rule(#"[ \t]+(?=\n|$)"#, "")
  private static let excessBreaks = rule(#"\n{3,}"#, "\n\n")

  private static func rule(_ pattern: String, _ template: String) -> Rule {
    // Patterns are literals; a typo is a programming error caught by the unit tests.
    // swiftlint:disable:next force_try
    Rule(
      regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      template: template)
  }

  /// Text with no command in it comes back byte for byte unchanged.
  static func apply(to text: String, mode: PunctuationMode = .automatic) -> String {
    var result = text
    var changed = false
    for rule in mode == .spokenOnly ? rules + spokenOnlyRules : rules {
      let range = NSRange(result.startIndex..., in: result)
      guard rule.regex.firstMatch(in: result, range: range) != nil else { continue }
      result = rule.regex.stringByReplacingMatches(
        in: result, range: range, withTemplate: rule.template)
      changed = true
    }
    guard changed else { return text }
    result = capitalizeAfterGluedColon(result)
    for cleanup in [trailingSpaceBeforeBreak, excessBreaks] {
      let range = NSRange(result.startIndex..., in: result)
      result = cleanup.regex.stringByReplacingMatches(
        in: result, range: range, withTemplate: cleanup.template)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
