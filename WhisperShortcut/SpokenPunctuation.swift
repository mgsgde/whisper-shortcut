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
/// to saying the marks, so "Punkt", "Komma", "Fragezeichen", "Ausrufezeichen", "Schrägstrich"
/// and "drei Pünktchen" are converted too.
enum SpokenPunctuation {
  /// Folded (`GlossaryDocument.fold`) single words the rules below turn into layout or marks.
  /// Mirrors the spoken words in `rules` and `spokenOnlyRules`; `ParakeetVocabularyGuard` never
  /// lets a glossary boost rewrite one of them. Keep in sync when a rule gains a word.
  static let commandWords: Set<String> = [
    "doppelpunkt", "komma", "punkt", "fragezeichen", "ausrufezeichen", "schragstrich",
    "schraegstrich", "schreckstrich", "semikolon", "strichpunkt", "punktchen", "puenktchen",
    "auslassungspunkte", "absatz", "zeile",
  ]

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
    // The model already ended the sentence ("Anamnese. Neuer Absatz, die Klägerin"): the next word
    // starts the new paragraph or line, so it gets a capital (marker, `capitalizeAfterGluedColon`).
    rule(#"(?<=[.!?])[ \t]*\bneue[rn][ \t]+absatz\b[ \t,.;:!?]*"#, "\n\n\u{1}"),
    rule(#"(?<=[.!?])[ \t]*\bneue[ \t]+zeile\b[ \t,.;:!?]*"#, "\n\u{1}"),
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
    // "ich Schrägstrich sage" → "ich/sage". Also "Schraegstrich", the mishearing "Schreckstrich",
    // and a split "Schräg Strich" / "Schräg-Strich". Spaces and stray ASR commas/semicolons before
    // it go; a period stays ("usw. Schrägstrich b" → "usw./b"). "Schrägstriche" (plural) does not
    // match; the glued form ("Schrägstrichsage") does. Spoken-only: in automatic mode, and in
    // Dictate Prompt instructions ("ersetze jeden Schrägstrich …"), the word is an ordinary noun.
    rule(#"[ \t,;]*\bschr(?:ä|ae|e)(?:g|ck)[ \t-]?strich\b[ \t,.;]*"#, "/"),
    rule(#"[ \t,;]*\bschr(?:ä|ae|e)(?:g|ck)[ \t-]?strich(?!(?:e|en|es|s)\b)(?=\p{L})"#, "/"),
    // "3 Komma 5 cm" → "3,5 cm": a decimal comma, no spaces. Must run before the plain "Komma" rule.
    // Only a single pair: "3 Komma 5 Komma 4" is a list and gets plain commas below. The same pair
    // said in words ("zwei Komma fünf" → "2,5") is `decimalCommaBetweenNumberWords` in `apply`:
    // the words map to digits, so a replacement template cannot do it.
    rule(#"(?<!\bkomma[ \t]\d{1,6})(?<=\d)[ \t]*\bkomma\b[ \t]*(?=\d)(?!\d+[ \t]*\bkomma\b[ \t]*\d)"#, ","),
    rule(#"[ \t,;]*\bfragezeichen\b[ \t,.;]*"#, "? \u{1}"),
    rule(#"[ \t,;]*\bausrufezeichen\b[ \t,.;]*"#, "! \u{1}"),
    // "drei Pünktchen", "drei Puenktchen", "Auslassungspunkte" → "…", attached to the previous
    // word. Spaces and a stray comma or semicolon before it go; comma, period and semicolon after
    // it go too. Not "drei Punkte" (a score). Before "Punkt", so "Pünktchen" is not read as one.
    rule(
      #"[ \t,;]*\b(?:drei[ \t]+p(?:ü|ue)nktchen|auslassungspunkte)\b[ \t,.;]*"#,
      "… "),
    // Not the noun: "Punkt 3", "Punkt drei", "Siehe Punkt 2.1", "zu Punkt", "der wichtigste Punkt".
    // A following number word counts as the number, same as a digit ("Unter Punkt drei steht").
    rule(
      #"[ \t,;]*(?<!\b(?:zu|unter|im|in|der|den|dem|des|einen|einem|ein|jeden|letzten|wichtigste|wichtigsten)[ \t])\bpunkt\b(?![ \t]*(?:\d|(?:eins|zwei|drei|vier|fünf|fuenf|sechs|sieben|acht|neun|zehn|elf|zwölf|zwoelf)\b))[ \t,.;]*"#,
      ". \u{1}"),
    rule(#"[ \t,;]*\bkomma\b[ \t,.;]*"#, ", "),
  ]

  /// Removes the punctuation an offline model inserted on its own (`. , ; ! ?`) for
  /// `PunctuationMode.spokenOnly`. Only marks followed by whitespace or the end of the text, so
  /// "3.5" and "1,2" survive. A single period stays when it belongs to the text rather than ending
  /// a sentence: after a digit and before a space ("3. November", "5. Lendenwirbel") and after one
  /// of `keptAbbreviations` ("Dr. Müller", "z. B.", any single letter). A model comma glued to a
  /// kept period is dropped alone. Parakeet capitalises the word after its own period; once a
  /// sentence mark (`.!?`, not a kept period and not a comma or semicolon) is gone, a following
  /// function word (`lowercasingFunctionWord`) is written lower-case again. A noun, a verb and the
  /// formal "Sie" keep the capital. A spoken "Punkt" puts that capital back later, in `apply`.
  /// Run before `apply`.
  static func stripModelPunctuation(from text: String) -> String {
    let nsText = text as NSString
    var result = text
    let matches = stripRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    for match in matches.reversed() {
      var range = match.range
      if nsText.character(at: range.location) == 0x2E,
        periodBelongsToText(in: nsText, at: NSRange(location: range.location, length: 1))
      {
        // Keep the text's period; a model mark glued to it (".,") still goes.
        if range.length == 1 { continue }
        range = NSRange(location: range.location + 1, length: range.length - 1)
      }
      guard let swiftRange = Range(range, in: result) else { continue }
      // The prefix is still the original text (matches are removed from the end), so the
      // original UTF-16 range still addresses it. Rebuilding avoids using a String index
      // across the edit.
      let prefix = String(result[..<swiftRange.lowerBound])
      var suffix = String(result[swiftRange.upperBound...])
      if sentenceMark(nsText.substring(with: range)) {
        suffix = lowercasingLeadingFunctionWord(suffix)
      }
      result = prefix + suffix
    }
    return result
  }

  /// A comma or semicolon does not start the next word: "Hallo, Welt" stays "Hallo Welt".
  private static func sentenceMark(_ removed: String) -> Bool {
    removed.contains { $0 == "." || $0 == "!" || $0 == "?" }
  }

  /// `suffix` starts where the sentence mark was. Skip whitespace, then the next word.
  private static func lowercasingLeadingFunctionWord(_ suffix: String) -> String {
    var index = suffix.startIndex
    while index < suffix.endIndex, suffix[index].isWhitespace {
      index = suffix.index(after: index)
    }
    guard index < suffix.endIndex else { return suffix }
    var end = index
    while end < suffix.endIndex, !suffix[end].isWhitespace {
      end = suffix.index(after: end)
    }
    let word = String(suffix[index..<end])
    guard let lowered = lowercasingFunctionWord(word) else { return suffix }
    return String(suffix[..<index]) + lowered + String(suffix[end...])
  }

  /// The lower-case spelling of a German function word Parakeet capitalised on its own, or nil.
  /// Whole word. "Sie", "Ihr" and "Ihnen" are not function words here: they are the formal
  /// address and must stay capital ("Wir bitten Sie"). Nouns and verbs are absent too, so they
  /// keep the capital Parakeet wrote. Live dictation reuses this at a piece boundary.
  static func lowercasingFunctionWord(_ word: String) -> String? {
    guard let first = word.first, first.isUppercase else { return nil }
    guard functionWords.contains(word.lowercased()) else { return nil }
    return first.lowercased() + word.dropFirst()
  }

  /// Lower-case forms. "sie" is omitted on purpose — see `lowercasingFunctionWord`.
  private static let functionWords: Set<String> = [
    "und", "oder", "aber", "sondern", "denn", "weil", "dass", "ob", "wenn", "als", "wie",
    "mit", "bei", "nach", "von", "vor", "zu", "zum", "zur", "aus", "auf", "an", "am",
    "im", "in", "über", "unter", "seit", "für", "durch", "gegen", "ohne", "um",
    "ist", "sind", "war", "waren", "hat", "haben", "wird", "wurde", "sich", "nicht",
    "auch", "noch", "schon", "sehr", "er", "es", "wir", "man",
    "der", "die", "das", "den", "dem", "des",
    "ein", "eine", "einen", "einem", "einer",
  ]

  /// Abbreviations whose period is kept (case-sensitive, whole word).
  private static let keptAbbreviations: Set<String> = [
    "Dr", "Prof", "Nr", "z", "B", "u", "a", "bzw", "ca", "usw", "ggf", "S", "Abs", "Art", "vgl",
    "evtl", "inkl", "Hr", "Fr", "St", "Tel", "Str",
    "med", "habil", "Az", "Abb", "Anl", "Bl", "geb", "tgl", "f", "ff", "Ziff", "bzgl", "etc", "sog",
    "lt", "gem", "Mio", "Std", "Min", "max", "min", "Jh", "Hrsg", "Aufl", "Kap", "Tab", "Anm",
    "Mrd", "Tsd", "Dipl", "Ing", "dent", "rer", "nat",
    // Chart shorthand, weekdays and months. "So" is not here: it is the word in "Das ist so."
    // "Fr" is already listed above.
    "Pat", "Diagn", "chron", "Bsp", "Pkt", "Mo", "Di", "Mi", "Do", "Sa",
    "Jan", "Feb", "Apr", "Aug", "Sep", "Sept", "Okt", "Nov", "Dez",
  ]

  private static func periodBelongsToText(in text: NSString, at range: NSRange) -> Bool {
    // The word (letters) right before the period.
    var start = range.location
    while start > 0, isLetter(text.character(at: start - 1)) { start -= 1 }
    if start < range.location {
      let word = text.substring(with: NSRange(location: start, length: range.location - start))
      // Any single letter is an abbreviation ("d. h.", "i. d. R."); "Hauptstr." ends in "str".
      return word.count == 1 || keptAbbreviations.contains(word) || word.lowercased().hasSuffix("str")
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
  /// "Punkt Punkt" leaves ". \u{1}. \u{1}". The copies collapse to one mark. The capital marker
  /// counts as whitespace between them, so it is not what separates two marks, and the marker
  /// after the last copy is left in place for `capitalizeAfterGluedColon` ("Ende. Weiter").
  private static let repeatedMarks = rule("([.,!?])(?:[ \t\u{1}]*\\1)+", "$1")

  private static let numberWordBody =
    "null|eins|ein|zwei|drei|vier|fünf|fuenf|sechs|sieben|acht|neun"
  private static let numberWordDigits: [String: String] = [
    "null": "0", "ein": "1", "eins": "1", "zwei": "2", "drei": "3", "vier": "4",
    "fünf": "5", "fuenf": "5", "sechs": "6", "sieben": "7", "acht": "8", "neun": "9",
  ]
  // swiftlint:disable:next force_try
  private static let decimalNumberWordRegex = try! NSRegularExpression(
    pattern: #"\b(\#(numberWordBody))\b[ \t]+\bkomma\b[ \t]+\b(\#(numberWordBody))\b"#,
    options: [.caseInsensitive])
  // A pair that continues a list ("zwei Komma fünf Komma vier", "Komma zwei Komma fünf") stays
  // words, the same way "3 Komma 5 Komma 4" stays digits with plain commas. `$` / `^` are the
  // ends of the text on either side of one pair, not of the whole line.
  // swiftlint:disable:next force_try
  private static let decimalChainBeforeRegex = try! NSRegularExpression(
    pattern: #"\bkomma[ \t]+$"#, options: [.caseInsensitive])
  // swiftlint:disable:next force_try
  private static let decimalChainAfterRegex = try! NSRegularExpression(
    pattern: #"^[ \t]+\bkomma\b[ \t]+\b(?:\#(numberWordBody))\b"#, options: [.caseInsensitive])

  /// "zwei Komma fünf" → "2,5". Nil when nothing matched, so `apply` can return its input
  /// unchanged. Only one pair: a "Komma" directly before the first word, or a number word
  /// directly after the second, means a list.
  private static func decimalCommaBetweenNumberWords(_ text: String) -> String? {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    let matches = decimalNumberWordRegex.matches(in: text, range: full)
    guard !matches.isEmpty else { return nil }
    var result = text
    var changed = false
    for match in matches.reversed() {
      guard match.numberOfRanges == 3 else { continue }
      let whole = match.range
      let prefix = ns.substring(to: whole.location)
      let suffix = ns.substring(from: whole.location + whole.length)
      if regexMatches(decimalChainBeforeRegex, prefix) || regexMatches(decimalChainAfterRegex, suffix) {
        continue
      }
      let left = ns.substring(with: match.range(at: 1)).lowercased()
      let right = ns.substring(with: match.range(at: 2)).lowercased()
      guard let d1 = numberWordDigits[left], let d2 = numberWordDigits[right],
        let swiftRange = Range(whole, in: result)
      else { continue }
      result.replaceSubrange(swiftRange, with: "\(d1),\(d2)")
      changed = true
    }
    return changed ? result : nil
  }

  private static func regexMatches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return regex.firstMatch(in: text, range: range) != nil
  }

  private static func rule(_ pattern: String, _ template: String) -> Rule {
    // Patterns are literals; a typo is a programming error caught by the unit tests.
    // swiftlint:disable:next force_try
    Rule(
      regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      template: template)
  }

  /// Text with no command in it comes back byte for byte unchanged. `keepsEdgeBreaks` trims only
  /// spaces and tabs at the start/end, not line breaks — for a piece in Dictate Live, where a
  /// trailing "neuer Absatz" must leave its "\n\n" for `LiveChunkJoiner` to lay out the next piece
  /// against; the default trims newlines too, exactly as before.
  static func apply(to text: String, mode: PunctuationMode = .automatic, keepsEdgeBreaks: Bool = false) -> String {
    var result = text
    var changed = false
    if mode == .spokenOnly, let decimals = decimalCommaBetweenNumberWords(result) {
      result = decimals
      changed = true
    }
    for rule in mode == .spokenOnly ? rules + spokenOnlyRules : rules {
      let range = NSRange(result.startIndex..., in: result)
      guard rule.regex.firstMatch(in: result, range: range) != nil else { continue }
      result = rule.regex.stringByReplacingMatches(
        in: result, range: range, withTemplate: rule.template)
      changed = true
    }
    // Before `capitalizeAfterGluedColon`: the marker has to still be in the text, and a marker
    // between two copies of a mark has to count as the space that separates them.
    if mode == .spokenOnly {
      let range = NSRange(result.startIndex..., in: result)
      let collapsed = repeatedMarks.regex.stringByReplacingMatches(
        in: result, range: range, withTemplate: repeatedMarks.template)
      if collapsed != result {
        result = collapsed
        changed = true
      }
    }
    guard changed else { return text }
    result = capitalizeAfterGluedColon(result)
    for cleanup in [trailingSpaceBeforeBreak, excessBreaks] {
      let range = NSRange(result.startIndex..., in: result)
      result = cleanup.regex.stringByReplacingMatches(
        in: result, range: range, withTemplate: cleanup.template)
    }
    return result.trimmingCharacters(in: keepsEdgeBreaks ? .whitespaces : .whitespacesAndNewlines)
  }
}
