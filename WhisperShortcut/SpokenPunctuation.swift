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
/// to saying the marks, so "Punkt", "Komma", "Fragezeichen", "Ausrufezeichen" and "Schrägstrich"
/// are converted too.
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
  ]

  /// Only in `PunctuationMode.spokenOnly`, where the model adds no punctuation of its own. The mark
  /// attaches to the previous word with one space after; after ". ? !" the next word is
  /// capitalized (marker, see `capitalizeAfterGluedColon`). Run after `rules`.
  private static let spokenOnlyRules: [Rule] = [
    // "ich Schrägstrich sage" → "ich/sage". Spaces and stray ASR commas/semicolons before it go; a
    // period stays ("usw. Schrägstrich b" → "usw./b"). "Schrägstriche" (plural) does not match; the
    // glued form ("Schrägstrichsage") does. Spoken-only: in automatic mode, and in Dictate Prompt
    // instructions ("ersetze jeden Schrägstrich …"), the word is an ordinary noun.
    rule(#"[ \t,;]*\bschr(?:ä|ae)gstrich\b[ \t,.;]*"#, "/"),
    rule(#"[ \t,;]*\bschr(?:ä|ae)gstrich(?!(?:e|en|es|s)\b)(?=\p{L})"#, "/"),
    // "3 Komma 5 cm" → "3,5 cm": a decimal comma, no spaces. Must run before the plain "Komma" rule.
    rule(#"(?<=\d)[ \t]*\bkomma\b[ \t]*(?=\d)"#, ","),
    rule(#"[ \t,.;]*\bfragezeichen\b[ \t,.;]*"#, "? \u{1}"),
    rule(#"[ \t,.;]*\bausrufezeichen\b[ \t,.;]*"#, "! \u{1}"),
    rule(#"[ \t,.;]*\bpunkt\b[ \t,.;]*"#, ". \u{1}"),
    rule(#"[ \t,.;]*\bkomma\b[ \t,.;]*"#, ", "),
  ]

  /// Removes the punctuation an offline model inserted on its own (`. , ; ! ?`) for
  /// `PunctuationMode.spokenOnly`. Only marks followed by whitespace or the end of the text, so
  /// "3.5" and "1,2" survive. A single period stays when it belongs to the text rather than ending
  /// a sentence: after a digit and before a space ("3. November", "5. Lendenwirbel") and after one
  /// of `keptAbbreviations` ("Dr. Müller", "z. B."). Run before `apply`.
  static func stripModelPunctuation(from text: String) -> String {
    let nsText = text as NSString
    var result = text
    let matches = stripRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    for match in matches.reversed() {
      if match.range.length == 1, nsText.character(at: match.range.location) == 0x2E,
        periodBelongsToText(in: nsText, at: match.range)
      {
        continue
      }
      guard let swiftRange = Range(match.range, in: result) else { continue }
      result.removeSubrange(swiftRange)
    }
    return result
  }

  /// Abbreviations whose period is kept (case-sensitive, whole word).
  private static let keptAbbreviations: Set<String> = [
    "Dr", "Prof", "Nr", "z", "B", "u", "a", "bzw", "ca", "usw", "ggf", "S", "Abs", "Art", "vgl",
    "evtl", "inkl", "Hr", "Fr", "St", "Tel", "Str",
  ]

  private static func periodBelongsToText(in text: NSString, at range: NSRange) -> Bool {
    // The word (letters) right before the period.
    var start = range.location
    while start > 0, isLetter(text.character(at: start - 1)) { start -= 1 }
    if start < range.location {
      return keptAbbreviations.contains(text.substring(with: NSRange(location: start, length: range.location - start)))
    }
    // Directly after a digit, and followed by a space (not the end): an ordinal or a date.
    guard range.location > 0, let digit = Unicode.Scalar(text.character(at: range.location - 1)),
      CharacterSet.decimalDigits.contains(digit)
    else { return false }
    let next = range.location + range.length
    return next < text.length && text.character(at: next) == 0x20
  }

  private static func isLetter(_ unit: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return CharacterSet.letters.contains(scalar)
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
      // The marker survives spaces and line breaks: "Punkt neue Zeile weiter" → ".\nWeiter".
      if upperNext, ch == " " || ch == "\t" || ch.isNewline {
        out.append(ch)
        continue
      }
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
