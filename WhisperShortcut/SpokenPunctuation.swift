import Foundation

/// Turns spoken layout commands into layout in offline transcripts.
///
/// Parakeet and local Whisper write a spoken "Doppelpunkt" or "neuer Absatz" out as words
/// ("Anamnese Doppelpunkt Patient berichtet …"), where cloud models that take a dictation prompt
/// already produce the punctuation. This is the deterministic fix for the offline engines only.
///
/// Deliberately narrow: "Punkt", "Komma" and "Fragezeichen" are ordinary German words ("der
/// wichtigste Punkt"), so they are left alone. Only phrases that are almost never meant literally in
/// dictation are converted, matched case-insensitively on whole words.
enum SpokenPunctuation {
  private struct Rule {
    let regex: NSRegularExpression
    let template: String
  }

  /// Order matters: the colon runs first so "Befund Doppelpunkt neuer Absatz" keeps its colon when
  /// the paragraph rule then strips the stray space before the break.
  private static let rules: [Rule] = [
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
  ]

  /// The glued-colon rule leaves a U+0001 marker before the word it split off; this upper-cases that
  /// word's first letter ("Doppelpunktdruckschmerz" → ": Druckschmerz") and drops the marker.
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
  static func apply(to text: String) -> String {
    var result = text
    var changed = false
    for rule in rules {
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
