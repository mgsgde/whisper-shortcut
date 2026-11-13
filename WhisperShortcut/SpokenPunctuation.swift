import Foundation

/// Turns spoken layout commands into layout in offline transcripts.
///
/// Parakeet and local Whisper write a spoken "Doppelpunkt", "Klammer auf" or "neuer Absatz" out as
/// words ("Anamnese Doppelpunkt Patient berichtet …"), where cloud models that take a dictation
/// prompt already produce the punctuation. This is the deterministic fix for the offline engines only.
///
/// Deliberately narrow: "Punkt", "Komma" and "Fragezeichen" are ordinary German words ("der
/// wichtigste Punkt"), so they are left alone. Only phrases that are almost never meant literally in
/// dictation are converted, matched case-insensitively on whole words. The exception is the
/// "Only when spoken" punctuation mode (`PunctuationMode.spokenOnly`): there the user has opted in
/// to saying the marks, so "Punkt", "Komma", "Fragezeichen", "Ausrufezeichen", "Semikolon",
/// "Strichpunkt", "Schrägstrich" and "drei Pünktchen" are converted too. There the model's own
/// commas and semicolons are removed (`stripModelPunctuation`). Without token timings its guessed
/// "?" and "!" are removed too; with timings (`timedMarks`) those marks were already kept or
/// dropped by `ParakeetPunctuationTiming`, so they stay. Its "." and ":" are kept, because the
/// model often writes a spoken "Punkt" as "." itself.
enum SpokenPunctuation {
  /// Folded (`GlossaryDocument.fold`) single words the rules below turn into layout or marks.
  /// Mirrors the spoken words in `rules` and `spokenOnlyRules`; `ParakeetVocabularyGuard` never
  /// lets a glossary boost rewrite one of them. Keep in sync when a rule gains a word.
  static let commandWords: Set<String> = [
    "doppelpunkt", "doppelgun", "komma", "punkt", "fragezeichen", "ausrufezeichen", "schragstrich",
    "schraegstrich", "schreckstrich", "semikolon", "strichpunkt", "punktchen", "puenktchen",
    "auslassungspunkte", "absatz", "zeile", "klammer", "klammerauf", "klammerzu",
    "neuzeile", "neuezeile",
  ]

  private struct Rule {
    let regex: NSRegularExpression
    let template: String
  }

  /// "Klammer auf", also glued or hyphenated ("Klammerauf", "Klammer-auf"). An article right after
  /// it is the noun ("eine Klammer auf die Wunde"), not the command.
  private static let openingParenGuarded =
    #"\bklammer[ \t-]*auf\b(?![ \t,.;]*(?:die|der|den|dem|das|eine|einen|einer|einem)\b)"#
  /// In "Only when spoken" a "Klammer zu" in the same text proves "Klammer auf" is the command,
  /// whatever article follows ("Klammer auf die Laborwerte … Klammer zu").
  private static let openingParenPlain = #"\bklammer[ \t-]*auf\b"#
  private static let closingParen = #"\bklammer[ \t-]*zu\b"#
  // swiftlint:disable:next force_try
  private static let parenPairRegex = try! NSRegularExpression(
    pattern: #"\bklammer[ \t-]*auf\b[\s\S]*\bklammer[ \t-]*zu\b"#, options: [.caseInsensitive])

  /// Order matters: the colon runs first so "Befund Doppelpunkt neuer Absatz" keeps its colon when
  /// the paragraph rule then strips the stray space before the break. Brackets run before the
  /// breaks, so a following "neue Zeile" still sees the parenthesis.
  /// The `rules` for one combination: `timed` = spoken-only text whose commas the token timing
  /// already called spoken (they are kept before a break), `parenAlways` = "Klammer auf" is
  /// converted even before an article. Index = `(timed ? 2 : 0) + (parenAlways ? 1 : 0)`.
  private static let ruleSets: [[Rule]] = (0..<4).map {
    makeRules(timed: $0 & 2 != 0, parenAlways: $0 & 1 != 0, dropSplitKomma: true)
  }
  /// Automatic mode: "Klammer zu" is a command only after an unmatched "(" ("um die Klammer zu
  /// entfernen" is a sentence). Spoken-only keeps it unguarded: Dictate Live decodes piece by
  /// piece, and the closing half can arrive in a piece that does not hold its "(".
  private static let automaticRules = makeRules(timed: false, parenAlways: false, requiresOpenParen: true)

  /// Lookbehind: a "(" earlier in the text with no ")" in between.
  private static let openParenBefore = #"(?<=\([^()]{0,2000})"#
  /// "neue Zeile" right after an article or determiner is the noun phrase ("eine neue Zeile in
  /// der Tabelle"), not the command. Placed directly before `\bneu…`.
  private static let notAfterDeterminer =
    #"(?<!\b(?:eine|einer|einen|einem|die|der|den|dem|jede|jeder|jeden|keine|keiner|diese|dieser|ihre|seine|meine|deine|unsere)[ \t])"#

  private static func makeRules(
    timed: Bool, parenAlways: Bool, requiresOpenParen: Bool = false,
    dropSplitKomma: Bool = false
  ) -> [Rule] {
    let openingParen = parenAlways ? openingParenPlain : openingParenGuarded
    let openGuard = requiresOpenParen ? openParenBefore : ""
    let zeile = notAfterDeterminer
    return [
    // The colon is already there — a model reply that kept the spoken word after its own heading
    // ("Befund: Doppelpunkt Druckschmerz", "Anamnese:\nDoppelpunkt Patientin"). Drop the word only.
    // "Doppel Punkt" and "Doppel-Punkt" are the same command split or hyphenated by Parakeet.
    rule(#"(:[ \t]*\n?[ \t]*)\bdoppel[ \t-]?(?:punkt|gun)\b[ \t,.;:]*"#, "$1"),
    // "Anamnese Doppelpunkt Patient" / "Befund, Doppelpunkt. Inspektion" → "Befund: Inspektion".
    // The optional "-" is Parakeet gluing "-Doppelpunkt" onto the word before ("Anamnese-Doppelpunkt").
    // Eats the punctuation the ASR put around the words on both sides. Inflections
    // ("Doppelpunkte") stay: the word boundary after "punkt" fails.
    rule(#"[ \t,.;]*-?\bdoppel[ \t-]?(?:punkt|gun)\b[ \t,.;:]*"#, ": "),
    // Parakeet sometimes glues the command onto the next word ("Befund Doppelpunktdruckschmerz").
    // The following word's first letter is upper-cased afterwards (`capitalizeAfterGluedColon`).
    // Inflections of the noun itself ("Doppelpunkte", "-en", "-es", "-s") are left alone.
    rule(#"[ \t,.;]*-?\bdoppel[ \t-]?punkt(?!(?:e|en|es|s)\b|setzung|zeichen|taste|symbol)(?=\p{L})"#, ": \u{1}"),
    // "(" keeps one space before it and none after, except at the start of the text or a line,
    // where there is no space before it either. Stray ASR commas and periods around the words go.
    rule(#"(^|\n)[ \t,.;]*\#(openingParen)[ \t,.;]*"#, "$1("),
    rule(#"[ \t,.;]*\#(openingParen)[ \t,.;]*"#, " ("),
    // ")" has no space before it. A comma the ASR put after it goes (one space stays before the
    // next word); a period after it stays ("Anlage Klammer zu."). The period and comma before it go.
    rule(#"\#(openGuard)[ \t,.;]*\#(closingParen)[ \t]*,[ \t]*"#, ") "),
    rule(#"\#(openGuard)[ \t,.;]*\#(closingParen)"#, ")"),
    // A comma before a spoken paragraph break is the ASR marking the pause; the sentence ended.
    // No capital marker: this stays ".\n\n", and the next word keeps the case it was spoken with.
    // "Neuerabsatz" / "Neuenabsatz" are the glued forms (no space).
    // With token timing (`timed`) a leftover comma is a spoken one ("Herren, neuer Absatz" is the
    // salutation's comma): it stays, as ",\n\n", and the break rule does not turn it into a period.
    rule(#"[ \t]*,[ \t]*\bneue[rn][ \t]*absatz\b[ \t,.;:!?]*"#, timed ? ",\n\n" : ".\n\n"),
    // The model already ended the sentence ("Anamnese. Neuer Absatz, die Klägerin"): the next word
    // starts the new paragraph or line, so it gets a capital (marker, `capitalizeAfterGluedColon`).
    // "Neuzeile" / "Neuezeile" are "neue Zeile" glued into one word. "Neuzeilen" does not match.
    rule(#"(?<=[.!?])[ \t]*\bneue[rn][ \t]*absatz\b[ \t,.;:!?]*"#, "\n\n\u{1}"),
    rule(#"(?<=[.!?])[ \t]*\#(zeile)\bneu(?:e[ \t]*)?zeile\b[ \t,.;:!?]*"#, "\n\u{1}"),
    // Paragraph break without a sentence mark before it. The next word still starts the new
    // paragraph, so it gets a capital too. A comma before "neuer Absatz" never reaches this rule —
    // the rule above already turned it into a period — so the comma in the prefix only restores
    // the old pattern.
    rule(#"[ \t,;]*\bneue[rn][ \t]*absatz\b[ \t,.;:!?]*"#, "\n\n\u{1}"),
    // A comma or semicolon before "neue Zeile" is the pause Parakeet wrote. Token timing keeps
    // those pause commas in "Only when spoken", so eating them here is what stops
    // "Befund, neue Zeile Inspektion" from staying "Befund,\nInspektion". No capital marker: the
    // next word keeps the case it was spoken with ("Herr Müller, neue Zeile vielen" →
    // "Herr Müller\nvielen"). A spoken "Komma" is still the word at this point; it becomes ","
    // only in the spoken-only rules, and `commaKeepsFollowingCase` then drops the marker.
    // With token timing (`timed`) a comma is the speaker's ("Müller, neue Zeile vielen Dank" →
    // "Müller,\nvielen Dank"), so it stays in front of the break.
    timed
      ? rule(#"[ \t]*,[ \t,;]*\#(zeile)\bneu(?:e[ \t]*)?zeile\b[ \t,.;:!?]*"#, ",\n")
      : rule(#"[ \t]*[,;][ \t,;]*\#(zeile)\bneu(?:e[ \t]*)?zeile\b[ \t,.;:!?]*"#, "\n"),
    // Line break without a sentence mark or a pause comma before it. The next word starts the
    // new line, so it gets a capital.
    rule(#"[ \t;]*\#(zeile)\bneu(?:e[ \t]*)?zeile\b[ \t,.;:!?]*"#, "\n\u{1}"),
    // Parakeet glues this one onto the next word too ("neue Zeileinspektion", "Neuzeileinspektion",
    // live capture 2026-10-20). A comma or semicolon before the glued command is the same pause
    // and is eaten; the split-off word still gets a capital. "neue Zeilen…" is left alone: the
    // "n" is the plural or a compound ("Zeilenumbrüche"), said literally. "Neue Teile" is a
    // different phrase and does not match.
    rule(#"[ \t,;]*\#(zeile)\bneu(?:e[ \t]*)?zeile(?!n)(?=\p{L})"#, "\n\u{1}"),
    ] + (dropSplitKomma ? [
      // Parakeet splits a spoken "Komma" before a pause into "," + "ma"
      // ("Heute ist ein schöner Tag, ma"). Only the bare lowercase word, so "Ma",
      // "Mama", "man" and "machen" stay. One space when more text follows on the
      // line; nothing at the end, before a line break, or before another mark.
      // Spoken rule sets only: automaticRules leaves the word.
      rule(
        #",[ \t]*(?-i:ma)\b(?:([ \t])[ \t]*(?=[^\s.,;:!?])|[ \t]*(?=$|\n|[.,;:!?]))"#,
        ",$1"),
    ] : [])
  }

  private static let punktNumberWords =
    "eins|zwei|drei|vier|fünf|fuenf|sechs|sieben|acht|neun|zehn|elf|zwölf|zwoelf"
  private static let punktFunctionWordAlternation =
    functionWords.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")

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
    // Parakeet glues the word onto the word before it: "Arbeitsmarktschrägstrich im ADL" →
    // "Arbeitsmarkt/im ADL". Needs a letter directly before, so it never overlaps the rules above.
    rule(#"(?<=\p{L})schr(?:ä|ae|e)(?:g|ck)[ \t-]?strich\b[ \t,.;]*"#, "/"),
    // Glued on both sides ("Arbeitsmarktschrägstrichbewegung" → "Arbeitsmarkt/Bewegung"). Parakeet
    // wrote the right part lower-case only because it was one word with the rest; it starts a
    // word of its own now, so it gets a capital (marker, see `capitalizeAfterGluedColon`). Case
    // is not guessed anywhere else: a glued right part with a space on the left keeps its letters.
    rule(#"(?<=\p{L})schr(?:ä|ae|e)(?:g|ck)[ \t-]?strich(?!(?:e|en|es|s)\b)(?=\p{L})"#, "/\u{1}"),
    // "3 Komma 5 cm" → "3,5 cm": a decimal comma, no spaces. Must run before the plain "Komma" rule.
    // Only a single pair: "3 Komma 5 Komma 4" is a list and gets plain commas below. The same pair
    // said in words ("zwei Komma fünf" → "2,5") is `decimalCommaBetweenNumberWords` in `apply`:
    // the words map to digits, so a replacement template cannot do it.
    rule(#"(?<!\bkomma[ \t]\d{1,6})(?<=\d)[ \t]*\bkomma\b[ \t]*(?=\d)(?!\d+[ \t]*\bkomma\b[ \t]*\d)"#, ","),
    // A sentence mark the model wrote right before the word ("Gut. Fragezeichen") is swallowed.
    rule(#"[ \t,;]*(?:[.!?][ \t]*)?\bfragezeichen\b[ \t,.;]*"#, "? \u{1}"),
    rule(#"[ \t,;]*(?:[.!?][ \t]*)?\bausrufezeichen\b[ \t,.;]*"#, "! \u{1}"),
    // "Hüfte frei beweglich Semikolon Knie" → "Hüfte frei beweglich; Knie". "Strichpunkt" is the
    // same mark. The words are in `commandWords`, so the glossary will not rewrite them; this is
    // the rule that actually converts them. A comma the model put on either side is the pause,
    // and goes. A period before the word stays ("usw. Semikolon"), the same way "Komma" leaves one.
    rule(#"[ \t,]*\b(?:semikolon|strichpunkt)\b[ \t,.;]*"#, "; "),
    // "drei Pünktchen", "drei Puenktchen", "Auslassungspunkte" → "…", attached to the previous
    // word. Spaces and a stray comma or semicolon before it go; comma, period and semicolon after
    // it go too. Not "drei Punkte" (a score). Before "Punkt", so "Pünktchen" is not read as one.
    // Parakeet also writes the count as a digit and glues or hyphenates it ("GDB3-Pünktchen",
    // "3 Pünktchen", "drei-Pünktchen"); the digit may sit directly on the previous word.
    rule(
      #"[ \t,;]*(?:(?:\bdrei|(?<!\d)3)[ \t-]*p(?:ü|ue)nktchen|\bauslassungspunkte)\b[ \t,.;]*"#,
      "… "),
    // ICD codes: "E11 Punkt 9" → "E11.9", "F33 Punkt 1" → "F33.1" (letter, 1-3 digits, Punkt, digit).
    rule(#"(?<=\b\p{L}\d{1,3})[ \t]*\bpunkt\b[ \t]*(?=\d)"#, "."),
    // A model period before or after the word ("vor. Punkt", "Punkt.") is swallowed: the
    // `repeatedMarks` pass collapses the pair to one mark.
    // Not the noun: "Siehe Punkt 2.1", "zu Punkt", "der wichtigste Punkt". A number (digit or number
    // word) after "Punkt" only keeps the noun when "Punkt" follows a preposition ("Siehe Punkt 2",
    // "vgl. Punkt drei"); otherwise it is the command ("entlassen Punkt zwei Wochen später" →
    // "entlassen. Zwei Wochen später").
    rule(
      #"[ \t,;]*(?<!\b(?:zu|um|unter|im|in|der|den|dem|des|einen|einem|ein|jeden|letzten|wichtigste|wichtigsten)[ \t])\bpunkt\b(?!(?<=\b(?:siehe|vgl|auf|an|am|bei|von|nach|bis|ab|um|zum|zur|gemäß|laut)[ \t]punkt)[ \t]*(?:\d|(?:\#(punktNumberWords))\b))[ \t,.;]*"#,
      ". \u{1}"),
    // After a particle that is also a verb prefix ("morgens ein Punkt", "den Befund zu Punkt",
    // "wieder in Punkt") the word is the command, unless a number or a noun follows ("ein Punkt
    // mehr", "in Punkt 3", "zu Punkt Anamnese"): a capitalised word that is not a function word
    // counts as a noun. At the end of the text or piece it is always the command.
    rule(
      #"[ \t,;]*(?<=\b(?:zu|ein|in|einen)[ \t])\bpunkt\b(?![ \t]*(?:\d|(?:\#(punktNumberWords))\b|mehr\b|weniger\b|(?!(?:\#(punktFunctionWordAlternation))\b)(?-i:\p{Lu})))[ \t,.;]*"#,
      ". \u{1}"),
    rule(#"[ \t,;]*\bkomma\b[ \t,.;]*"#, ", "),
  ]

  /// Removes the marks an offline model guessed on its own, for `PunctuationMode.spokenOnly`:
  /// commas, semicolons, and — when no token timings are available — question marks and
  /// exclamation marks. Only marks followed by whitespace or the end of the text, so "1,2" and
  /// "a?b" survive. The model's "." and ":" stay: Parakeet often turns a spoken "Punkt" into "."
  /// itself, and stripping it destroyed marks the user did say. Without timings a "?" or "!" is
  /// different from a period: the model guesses it from intonation ("Die Dosis stimmt?"), while a
  /// spoken "Fragezeichen" / "Ausrufezeichen" is applied afterwards by `apply`, so the user's own
  /// words still work and never double. Stripping the model's "!" in that pass is what left a
  /// "." when Parakeet had written both ("nachreichen.!" → "nachreichen."): the period is kept
  /// on purpose, the exclamation was not. When a stripped "?" or "!" ended a sentence the model
  /// capitalised the next word; that word is lower-cased again if it is a function word
  /// ("Und weiter" → "und weiter"), nouns keep their capital (`lowercasingFunctionWord`).
  /// A model comma glued to a kept period ("z. B.,") loses the comma alone. A spoken mark next
  /// to a kept model mark does not double: see `repeatedMarks` and `spokenOnlyRules`. Run before
  /// `apply`.
  ///
  /// - Parameter timedMarks: the text is Parakeet's, already filtered by token timing
  ///   (`ParakeetPunctuationTiming`). The commas, periods, "?" and "!" left are the ones the
  ///   timing called spoken, so only semicolons are removed here. "?" and "!" stay as they are —
  ///   removing them turned a spoken "!" into the model's leftover ".".
  static func stripModelPunctuation(from text: String, timedMarks: Bool = false) -> String {
    var result = (timedMarks ? semicolonRegex : stripRegex).stringByReplacingMatches(
      in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    // Timing already kept or dropped each "?" and "!". Running `guessedSentenceMarkRegex` here
    // deleted a spoken "!" and left a "." Parakeet had written next to it.
    guard !timedMarks else { return result }
    let resultNS = result as NSString
    let matches = guessedSentenceMarkRegex.matches(
      in: result, range: NSRange(location: 0, length: resultNS.length))
    for match in matches.reversed() {
      var replacement = ""
      let gapRange = match.range(at: 1)
      let wordRange = match.range(at: 2)
      if gapRange.location != NSNotFound, wordRange.location != NSNotFound {
        let word = resultNS.substring(with: wordRange)
        replacement = resultNS.substring(with: gapRange) + (lowercasingFunctionWord(word) ?? word)
      } else if gapRange.location != NSNotFound {
        replacement = resultNS.substring(with: gapRange)
      }
      guard let swiftRange = Range(match.range, in: result) else { continue }
      result.replaceSubrange(swiftRange, with: replacement)
    }
    return result
  }

  /// The lower-case spelling of a German function word Parakeet capitalised on its own, or nil.
  /// Whole word. "Sie", "Ihr" and "Ihnen" are not function words here: they are the formal
  /// address and must stay capital ("Wir bitten Sie"). Nouns and verbs are absent too, so they
  /// keep the capital Parakeet wrote. Live dictation uses this at a piece boundary, where the
  /// next piece starts a new decode and Parakeet capitalises its first word.
  static func lowercasingFunctionWord(_ word: String) -> String? {
    guard let first = word.first, first.isUppercase else { return nil }
    guard functionWords.contains(word.lowercased()) else { return nil }
    return first.lowercased() + word.dropFirst()
  }

  /// Words that open the line after a salutation ("Sehr geehrte Frau Müller,⏎vielen Dank"). Parakeet
  /// capitalises them at the start of a piece; after a comma they are lower-case.
  private static let salutationFollowers: Set<String> = [
    "vielen", "ich", "anbei", "danke", "hiermit", "gerne", "gern", "leider", "herzlichen",
  ]

  /// Like `lowercasingFunctionWord`, for the first word after a line break that follows a comma
  /// (the salutation's): function words plus the usual openers ("vielen", "ich", "anbei", "danke").
  /// Nouns keep their capital.
  static func lowercasingAfterSalutationComma(_ word: String) -> String? {
    guard let first = word.first, first.isUppercase else { return nil }
    let lower = word.lowercased()
    guard functionWords.contains(lower) || salutationFollowers.contains(lower) else { return nil }
    return first.lowercased() + word.dropFirst()
  }

  /// Lower-case forms of function words and adverbs that are never nouns. "sie", "ihr" and "ihnen"
  /// are omitted on purpose — see `lowercasingFunctionWord`.
  static let functionWords: Set<String> = [
    "und", "oder", "aber", "sondern", "denn", "weil", "dass", "ob", "wenn", "als", "wie",
    "mit", "bei", "nach", "von", "vor", "zu", "zum", "zur", "aus", "auf", "an", "am",
    "im", "in", "über", "unter", "seit", "für", "durch", "gegen", "ohne", "um", "bis",
    "ist", "sind", "war", "waren", "hat", "haben", "wird", "wurde", "sich", "nicht",
    "auch", "noch", "schon", "sehr", "er", "es", "wir", "man",
    "der", "die", "das", "den", "dem", "des",
    "ein", "eine", "einen", "einem", "einer",
    "diese", "dieser", "diesen", "diesem", "dieses",
    "mein", "meine", "meinen", "meinem", "meiner", "meines",
    "dein", "deine",
    "seine", "seinen", "seinem", "seiner",
    "unser", "unsere", "unseren", "unserem", "unserer",
    "jeder", "jede", "jeden", "jedem", "jedes",
    "kein", "keine", "keinen", "keinem", "keiner",
    "weiter", "dann", "jetzt", "hier", "da", "dort", "so", "nur", "mal", "wieder", "bitte",
    "doch", "eben", "gerade", "eigentlich", "vielleicht", "also", "dabei", "dazu", "damit",
    "daher", "deshalb", "trotzdem", "bereits", "immer", "nie", "oft", "etwas", "sonst", "zwar",
    "jedoch", "insgesamt", "ebenfalls", "weiterhin", "zudem", "außerdem", "allerdings", "eher",
    "kaum", "fast", "ganz",
  ]

  // swiftlint:disable:next force_try
  private static let stripRegex = try! NSRegularExpression(pattern: #"[,;]+(?=\s|$)"#)
  // swiftlint:disable:next force_try
  private static let semicolonRegex = try! NSRegularExpression(pattern: #";+(?=\s|$)"#)
  // A model "?" / "!" at a word end, with the spaces and the word after it (group 1 and 2).
  // swiftlint:disable:next force_try
  private static let guessedSentenceMarkRegex = try! NSRegularExpression(
    pattern: #"[?!]+(?=\s|$)([ \t]+)?(\p{L}+)?"#)

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
  /// `repeatedMarks`, except for an ellipsis the speaker or model wrote: three or more dots with
  /// nothing between them ("usw... und so") stay as they are. Duplicates the rules produce
  /// (". .", ",,") still collapse.
  private static func collapsingRepeatedMarks(_ text: String) -> String {
    let ns = text as NSString
    var result = text
    let matches = repeatedMarks.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    for match in matches.reversed() {
      let run = ns.substring(with: match.range)
      if run.count >= 3, run.allSatisfy({ $0 == "." }) { continue }
      guard let range = Range(match.range, in: result) else { continue }
      result.replaceSubrange(range, with: String(run.first ?? "."))
    }
    return result
  }

  /// A spoken "Komma" becomes a comma only in the spoken-only rules, after the break was inserted
  /// ("Komma neue Zeile vielen" → ",\n\u{1}vielen"). The plain break marked the next word for a
  /// capital; drop that marker so it keeps the case it was spoken with. A model comma before
  /// "neue Zeile" never reaches this: the break rule above already ate it.
  private static let commaKeepsFollowingCase = rule("(,[ \\t]*\\n+)\u{1}", "$1")

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
  ///
  /// `timedMarks`: the text is Parakeet's, already filtered by token timing, so a comma left in
  /// front of "neuer Absatz" / "neue Zeile" was spoken and stays (spoken-only mode only).
  static func apply(
    to text: String, mode: PunctuationMode = .automatic, keepsEdgeBreaks: Bool = false,
    timedMarks: Bool = false
  ) -> String {
    var result = text
    var changed = false
    if mode == .spokenOnly, let decimals = decimalCommaBetweenNumberWords(result) {
      result = decimals
      changed = true
    }
    let activeRules: [Rule]
    if mode == .spokenOnly {
      let parenAlways = regexMatches(parenPairRegex, result)
      activeRules = ruleSets[(timedMarks ? 2 : 0) + (parenAlways ? 1 : 0)] + spokenOnlyRules
    } else {
      activeRules = automaticRules
    }
    for rule in activeRules {
      let range = NSRange(result.startIndex..., in: result)
      guard rule.regex.firstMatch(in: result, range: range) != nil else { continue }
      result = rule.regex.stringByReplacingMatches(
        in: result, range: range, withTemplate: rule.template)
      changed = true
    }
    // Before `capitalizeAfterGluedColon`: the marker has to still be in the text, and a marker
    // between two copies of a mark has to count as the space that separates them. A spoken
    // "Komma" has just become a comma in front of the break; drop its marker first so the next
    // word keeps its case. A model comma was already eaten by the break rule.
    if mode == .spokenOnly {
      let collapsed = collapsingRepeatedMarks(result)
      if collapsed != result {
        result = collapsed
        changed = true
      }
    }
    guard changed else { return text }
    let commaRange = NSRange(result.startIndex..., in: result)
    result = commaKeepsFollowingCase.regex.stringByReplacingMatches(
      in: result, range: commaRange, withTemplate: commaKeepsFollowingCase.template)
    result = capitalizeAfterGluedColon(result)
    for cleanup in [trailingSpaceBeforeBreak, excessBreaks] {
      let range = NSRange(result.startIndex..., in: result)
      result = cleanup.regex.stringByReplacingMatches(
        in: result, range: range, withTemplate: cleanup.template)
    }
    return result.trimmingCharacters(in: keepsEdgeBreaks ? .whitespaces : .whitespacesAndNewlines)
  }
}
