import Foundation

/// The one place offline transcript text is finished, for Dictate, Dictate Live and the onboarding test.
enum OfflineTranscriptFinisher {
  /// Fillers dropped (a leading "Oh" before a spoken colon goes too), a glued trailing "…punkt"
  /// split back apart in "Only when spoken" mode, model punctuation stripped in that mode, then
  /// the spoken layout commands, GdB spelling, and quantity number words as digits.
  ///
  /// Spelling runs before the number words, in every punctuation mode, so "EinzelgdB" is already
  /// the token "GdB" when the value rule looks for it. Spoken commands have already run, so
  /// "drei Pünktchen" is already "…" and "zwei Komma fünf" already "2,5".
  ///
  /// `keepsEdgeBreaks`: Dictate Live passes true so a trailing "neuer Absatz" stays "\n\n" for
  /// `LiveChunkJoiner`. Plain Dictate trims that edge break.
  /// `timedMarks`: the text is Parakeet's, already filtered by token timing, so strip removes only
  /// semicolons and a "?" or "!" the timing kept stays. Without timings, model "?" and "!" drop.
  static func finish(
    _ text: String, mode: PunctuationMode, timedMarks: Bool, keepsEdgeBreaks: Bool
  ) -> String {
    let withoutFillers = removingFillers(text)
    let unglued = mode == .spokenOnly ? splittingGluedTrailingPunkt(withoutFillers) : withoutFillers
    let source =
      mode == .spokenOnly
      ? SpokenPunctuation.stripModelPunctuation(from: unglued, timedMarks: timedMarks)
      : unglued
    let punctuated = SpokenPunctuation.apply(
      to: source, mode: mode, keepsEdgeBreaks: keepsEdgeBreaks, timedMarks: timedMarks)
    let spelled = GdBSpelling.normalize(punctuated)
    return GermanNumberWords.digitizingQuantities(in: spelled)
  }

  /// nil-safe convenience: returns `text` unchanged for cloud models.
  /// Offline models run `finish`. Parakeet keeps timing-filtered marks; other offline engines do not.
  static func finish(
    _ text: String, model: TranscriptionModel, mode: PunctuationMode, keepsEdgeBreaks: Bool = false
  ) -> String {
    guard model.isOffline else { return text }
    let timedMarks = model.offlineModelType?.engine == .parakeet
    return finish(text, mode: mode, timedMarks: timedMarks, keepsEdgeBreaks: keepsEdgeBreaks)
  }

  /// Parakeet glues a spoken "Punkt" before a pause onto the last word of the piece
  /// («Die Haut ist trockenpunkt»), so the spoken-punctuation rules never see the command. This
  /// splits it back to «trocken Punkt». Only the piece's last word is looked at (in ~20 live
  /// samples the glue was always on the last word, never mid-piece). Real "-punkt" compounds
  /// ("Triggerpunkt", "Zeitpunkt", also "Untersuchungszeitpunkt") stay via
  /// `SpokenPunctuation.isRealPunktCompound`: a last word that ends in `realPunktCompounds` stays.
  /// An explicit allow-list is used because Apple's spell checker calls "Kniepunkt" correct and
  /// "Triggerpunkt" wrong. Not a suffix match for `wholeWordOnlyPunktCompounds`: a glued
  /// "stechend"/"Blutdruck"/"Fleck"/"Juckreiz" + "punkt" would end in a listed word ("endpunkt",
  /// "druckpunkt", "eckpunkt", "reizpunkt"; "hochpunkt" and "lichtpunkt" are the same trap) and
  /// stay unsplit.
  /// Kill switch: UserDefaults bool `liveDisableGluedPunktSplit` (default false = step active).
  static func splittingGluedTrailingPunkt(_ text: String) -> String {
    if UserDefaults.standard.bool(forKey: "liveDisableGluedPunktSplit") { return text }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = gluedPunktRegex.firstMatch(in: text, range: range),
      let wordRange = Range(match.range(at: 1), in: text),
      let stemRange = Range(match.range(at: 2), in: text)
    else { return text }
    let word = String(text[wordRange])
    let lower = word.lowercased()
    if lower == "punkt" || lower == "doppelpunkt" || lower == "strichpunkt" { return text }
    if SpokenPunctuation.isRealPunktCompound(lower) { return text }
    let stem = String(text[stemRange])
    DebugLogger.log("LIVE-PUNKT: split glued «\(word)»")
    return text.replacingCharacters(in: wordRange, with: stem + " Punkt")
  }

  // swiftlint:disable:next force_try
  private static let gluedPunktRegex = try! NSRegularExpression(
    pattern: #"((\p{L}{2,})punkt)[.,;:!?…]*\s*$"#, options: [.caseInsensitive])

  /// Drops a leading "Oh" before a spoken colon, then the shared filler filter.
  private static func removingFillers(_ text: String) -> String {
    let text = leadingOhRegex.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    return TextProcessingUtility.removingFillers(text)
  }

  // Parakeet hears the breath before a lone spoken command as "Oh," ("Oh, Doppelpunkt." for a piece
  // that is only "Doppelpunkt"), which turned the colon into "Oh:". "Oh" stays a real word
  // everywhere else; it goes only at the start of a piece, right before a spoken colon.
  // swiftlint:disable:next force_try
  private static let leadingOhRegex = try! NSRegularExpression(
    pattern: #"^[ \t]*oh[,.]?[ \t]+(?=doppel[ \t-]?(?:punkt|gun)\b)"#,
    options: [.caseInsensitive])
}
