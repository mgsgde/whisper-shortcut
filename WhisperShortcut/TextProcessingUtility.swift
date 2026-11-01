//
//  TextProcessingUtility.swift
//  WhisperShortcut
//
//  Shared text processing utilities for transcription normalization and validation
//

import Foundation

// MARK: - Text Processing Utility
enum TextProcessingUtility {
  
  // MARK: - Text Normalization
  static func normalizeTranscriptionText(_ text: String) -> String {
    cleanTranscriptionText(normalizingWhitespace(text))
  }

  /// Trim, collapse runs of three or more newlines to two, and collapse spaces inside each line
  /// while keeping leading indentation. Shared with Dictate Prompt replies; leak stripping is not.
  static func normalizingWhitespace(_ text: String) -> String {
    // Remove excessive whitespace and normalize line breaks
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Preserve line breaks: normalize multiple spaces/tabs to single space, but keep newlines
    // Step 1: Normalize multiple consecutive newlines to max 2
    let normalizedNewlines = trimmed.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

    // Step 2: Normalize spaces/tabs within each line while preserving indentation (leading whitespace)
    // so bullet points and sub-bullets stay indented when pasted.
    let lines = normalizedNewlines.components(separatedBy: "\n")
    let normalizedLines = lines.map { line in
      // Trim only trailing whitespace; preserve leading whitespace for indentation
      let trimmedTrailing = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
      guard let firstNonWhitespace = trimmedTrailing.firstIndex(where: { !$0.isWhitespace }) else {
        return trimmedTrailing
      }
      let leading = String(trimmedTrailing[..<firstNonWhitespace])
      let rest = String(trimmedTrailing[firstNonWhitespace...])
      let collapsedRest = rest.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
      return leading + collapsedRest
    }
    return normalizedLines.joined(separator: "\n")
  }
  
  /// Strips a "here is the transcription…" lead-in the model wrote before the actual words.
  ///
  /// The literal prefix list below only catches exact spellings. Models get chattier the more they
  /// are allowed to think — with the thinking-effort setting raised, real observed answers were
  /// `**Transcription:**\nTesting 1, 2, 3.` (markdown bold defeats the literal match) and
  /// `Here is the transcription of the audio you provided: …` (the middle clause defeats it). Both
  /// would otherwise be pasted into the user's document verbatim.
  private static let transcriptionPreambleRegex = try! NSRegularExpression(
    // Markdown emphasis can wrap the label on either side of the colon — the observed answer was
    // literally `**Transcription:**`, so the trailing `[*_]*` is load-bearing.
    pattern: #"^\s*[*_#\s]*(?:(?:here|this|below)\s+(?:is|are)\s+)?(?:the\s+)?(?:audio\s+|full\s+|complete\s+)?transcription(?:\s+of\s+[^:\n]{0,80})?\s*:\s*[*_]*\s*"#,
    options: [.caseInsensitive])

  static func strippingTranscriptionPreamble(_ text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = transcriptionPreambleRegex.firstMatch(in: text, range: range),
          match.range.length > 0,
          let stripped = Range(match.range, in: text)
    else { return text }
    let result = String(text[stripped.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    // Never hand back an empty transcript: if the preamble was the whole answer, the caller's
    // validation should see the original and reject it, not silently receive "".
    guard !result.isEmpty else { return text }
    DebugLogger.log("PROMPT-CLEANUP: Removed model preamble \(DebugLogger.redacted(text[stripped]))")
    return result
  }

  // MARK: - Text Cleaning
  private static func cleanTranscriptionText(_ text: String) -> String {
    var cleaned = strippingTranscriptionPreamble(text)
    let originalLength = cleaned.count

    // Remove common prompt remnants that might appear at the beginning
    let promptPrefixes = [
      "convert speech to",
      "clean text with",
      "proper punctuation",
      "transcribe this audio",
      "please transcribe",
      "the transcription is:",
      "transcribed text:",
      "the audio says:"
    ]
    
    let lowercasedText = cleaned.lowercased()
    for prefix in promptPrefixes {
      // Word-boundary: "please transcribe this meeting for Sara" is real speech, not a leak.
      let atBoundary = lowercasedText.hasPrefix(prefix)
        && (cleaned.count == prefix.count
          || cleaned.dropFirst(prefix.count).first?.isWhitespace == true
          || cleaned.dropFirst(prefix.count).first == "\n"
          || prefix.hasSuffix(":") || prefix.hasSuffix("."))
      if atBoundary {
        DebugLogger.log("PROMPT-CLEANUP: Removed prefix: '\(prefix)' from transcription")
        cleaned = String(cleaned.dropFirst(prefix.count))
        break
      }
    }
    
    // Remove common prompt remnants that might appear at the end
    let promptSuffixes = [
      "with proper punctuation",
      "clean text with",
      "keep only the intended meaning",
      "remove filler words",
      "preserve correct punctuation",
      "numbers should be written as digits"
    ]
    
    for suffix in promptSuffixes {
      // Word boundary: "unremove filler words" is real speech. The suffix must be the whole
      // text, or the character before it must be whitespace or punctuation.
      guard lowercasedText.hasSuffix(suffix) else { continue }
      let atWordBoundary: Bool
      if lowercasedText.count == suffix.count {
        atWordBoundary = true
      } else {
        let suffixStart = lowercasedText.index(lowercasedText.endIndex, offsetBy: -suffix.count)
        let previous = lowercasedText[lowercasedText.index(before: suffixStart)]
        atWordBoundary = previous.isWhitespace || previous.isPunctuation
      }
      guard atWordBoundary else { continue }
      DebugLogger.log("PROMPT-CLEANUP: Removed suffix: '\(suffix)' from transcription")
      cleaned = String(cleaned.dropLast(suffix.count))
      break
    }
    
    // Clean up any remaining whitespace
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if cleaned.count != originalLength {
      DebugLogger.log("PROMPT-CLEANUP: Text cleaned: \(originalLength) -> \(cleaned.count) characters")
    }
    
    return cleaned
  }
  
  // MARK: - Hallucination Plausibility Gate

  /// Discards transcripts that are impossibly long for the recording duration. Flash-tier Gemini
  /// models sometimes fail to perceive very short recordings (~1 s) and confabulate
  /// paragraph-length "transcripts" from the prompt context instead (observed: 0.9 s of audio →
  /// 538 invented characters, i.e. ~600 chars/s). Returns the text unchanged when plausible, or ""
  /// when discarded — callers already treat empty output as "no speech detected".
  ///
  /// The ceiling has to stay far above real speech, because being wrong here destroys a *correct*
  /// transcript and reports "no speech detected", which is undiagnosable from the outside.
  /// Observed false positive at the previous 30 chars/s: recording a WhatsApp voice message played
  /// back at 2× speed produced four perfectly good transcripts of 957–1017 characters from ~31 s
  /// of audio (~33 chars/s) — every one of them thrown away, one of them by a single character.
  /// Anything that speeds speech up lands there: 2×/3× playback, a fast speaker, a dense language.
  ///
  /// 60 chars/s is roughly 3–4× normal speech and still leaves an order of magnitude of margin to
  /// the confabulation signature this gate exists for (the 0.9 s case above stays discarded by 5×).
  static func discardingImplausibleTranscript(
    _ text: String, audioDurationSeconds: Double, mode: String
  ) -> String {
    guard audioDurationSeconds > 0 else { return text }
    let maxPlausibleCharacters = Int(audioDurationSeconds * 60.0) + 40
    guard text.count > maxPlausibleCharacters else { return text }
    DebugLogger.logError(
      "\(mode): Discarding implausible transcript (\(text.count) chars from \(String(format: "%.1f", audioDurationSeconds))s audio, max plausible \(maxPlausibleCharacters))"
    )
    return ""
  }

  /// Lower bound of the same gate: discards transcripts that are implausibly *short* for the
  /// recording **and** made of nothing but glossary terms.
  ///
  /// Observed: a 6.3 s tail chunk of a 7-minute dictation came back as exactly `sabaki.dance`
  /// while the glossary carried both "Sabaki" and "Dance" — the model could not perceive the
  /// near-silent tail and emitted glossary vocabulary instead of nothing. The upper bound in
  /// `discardingImplausibleTranscript` cannot catch this: 12 characters are never "too long".
  ///
  /// Both conditions must hold, which is what keeps false positives out. A genuine short
  /// utterance ("Sabaki Dance", 12 chars from 1.5 s) clears the length floor and survives; a
  /// genuine short answer that is not glossary vocabulary ("Ja.") fails the content test and
  /// survives. Only "long audio, almost no text, and that text is verbatim glossary" is dropped.
  /// Returns "" when discarded — callers already treat empty output as "no speech detected".
  ///
  /// A second rule is independent of length: the transcript is the glossary read out in order.
  /// Observed: near-silent ~25 s live-meeting chunks returned the whole 36-term glossary (344
  /// chars), which the length floor cannot catch. Discarded when the words walk the glossary's
  /// terms front to back, consuming every word, and cover at least `minOrderedEchoTerms` terms.
  /// A real utterance made only of glossary names is short and rarely names four or more of
  /// them in exactly the glossary's order; the echo copies the list in order. The walk matches
  /// term by term (not word → first term) because a glossary can hold "Claude" and later
  /// "Claude Code", and the second "Claude" word must still count for the later term.
  ///
  /// Live-meeting chunks prefix each line with a speaker label. Observed 2026-10-28 (Gemini 3.1
  /// Flash-Lite): an 11.4 s near-silent chunk came back as "Speaker A: Claude Code." (23
  /// characters), and a ~25 s chunk as "Speaker A: Claude, Christoph, Michelbach, ..." — the whole
  /// glossary in glossary order. Both rules below judge the text with those labels removed; a
  /// transcript that is only labels is discarded.
  ///
  /// Connector words ("und", "and", "mit", ...) are neutral in both rules. Observed 2026-10-28
  /// (gpt-transcribe, live meeting, loud system audio): the model returned "Claude Code, MCP und
  /// Bachata." and a 29 s chunk of "X, Y und Z." triples — the glossary with "und" glued between
  /// terms, which neither rule caught because "und" is not a glossary word. Connectors may sit
  /// between terms, but a transcript made only of connectors is not an echo.
  static func discardingGlossaryEchoTranscript(
    _ text: String, audioDurationSeconds: Double, glossaryTerms: [String], mode: String
  ) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, audioDurationSeconds > 0, !glossaryTerms.isEmpty else { return text }

    // "Speaker A:" / "Sprecher A:" are not glossary words; both rules judge the words after them.
    let judged = strippingSpeakerLabels(trimmed)
    guard !judged.isEmpty else { return "" }
    let labelNote = judged != trimmed ? " (speaker labels ignored)" : ""

    // Real speech runs 10–20 chars/s; even slow, pause-heavy dictation stays above 5. Three
    // chars/s is far enough below that floor that only near-empty output trips it.
    let minPlausibleCharacters = audioDurationSeconds * 3.0
    if Double(judged.count) >= minPlausibleCharacters {
      if let termCount = orderedGlossaryEchoTermCount(judged, glossaryTerms: glossaryTerms),
        termCount >= minOrderedEchoTerms
      {
        DebugLogger.logError(
          "\(mode): Discarding glossary-echo transcript (ordered-list rule: \(termCount) glossary terms in glossary order, \(judged.count) chars from \(String(format: "%.1f", audioDurationSeconds))s audio)\(labelNote)"
        )
        return ""
      }
      return text
    }

    // Content test: every word in the transcript is a glossary term. Split on anything that
    // isn't a letter or digit so `sabaki.dance`, `Sabaki-Dance` and `Sabaki, Dance` all reduce
    // to the same two words.
    let folded = Set(glossaryTerms.flatMap { term in
      term.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map { foldForEchoCheck(String($0)) }
    })
    let words = judged.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map { foldForEchoCheck(String($0)) }
    guard !words.isEmpty,
      words.allSatisfy({ folded.contains($0) || echoConnectorWords.contains($0) }),
      words.contains(where: { folded.contains($0) })
    else { return text }

    DebugLogger.logError(
      "\(mode): Discarding glossary-echo transcript (\(judged.count) chars from \(String(format: "%.1f", audioDurationSeconds))s audio, min plausible \(String(format: "%.0f", minPlausibleCharacters)), short-text rule: all words are glossary terms)\(labelNote)"
    )
    return ""
  }

  private static let minOrderedEchoTerms = 4

  /// Filler the model glues between echoed terms; compared after `foldForEchoCheck`.
  private static let echoConnectorWords: Set<String> = [
    "und", "and", "mit", "with", "oder", "or", "sowie", "plus", "y", "et",
  ]

  /// Number of glossary terms the text spells out front to back, or nil unless *every* word of
  /// the text is consumed that way.
  private static func orderedGlossaryEchoTermCount(_ text: String, glossaryTerms: [String]) -> Int? {
    let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map { foldForEchoCheck(String($0)) }
    guard !words.isEmpty else { return nil }
    var position = 0
    var matched = 0
    for term in glossaryTerms where position < words.count {
      let termWords = term.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map { foldForEchoCheck(String($0)) }
      guard !termWords.isEmpty else { continue }
      func matches(at start: Int) -> Bool {
        start + termWords.count <= words.count
          && Array(words[start..<start + termWords.count]) == termWords
      }
      // Match the term first; only then fall back to skipping connectors in front of it.
      var start = position
      if !matches(at: start) {
        while start < words.count, echoConnectorWords.contains(words[start]) { start += 1 }
      }
      guard matches(at: start) else { continue }
      position = start + termWords.count
      matched += 1
    }
    while position < words.count, echoConnectorWords.contains(words[position]) { position += 1 }
    return position == words.count ? matched : nil
  }

  /// One leading "Speaker A:" / "Sprecher A:" per line. The joined remainder is trimmed.
  private static let speakerLabelPrefixRegex = try! NSRegularExpression(
    pattern: #"^\s*(Speaker|Sprecher)\s+[A-Za-z0-9]{1,3}\s*:\s*"#,
    options: [.caseInsensitive])

  private static func strippingSpeakerLabels(_ text: String) -> String {
    let strippedLines = text.components(separatedBy: "\n").map { line -> String in
      let range = NSRange(line.startIndex..., in: line)
      guard let match = speakerLabelPrefixRegex.firstMatch(in: line, range: range),
        let matched = Range(match.range, in: line)
      else { return line }
      return String(line[matched.upperBound...])
    }
    return strippedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Strips a glossary list the model appended after an otherwise correct dictation.
  ///
  /// Observed (glossary "Joschka, SumUp, lemniscus, WhisperShortcut"):
  /// A: "…im System gesperrt werden. Joschka SumUp lemniscus"
  /// B: "…WhisperShortcut zugeschickt. Joschka, SumUp, lemniscus, WhisperShortcut."
  /// `discardingGlossaryEchoTranscript` only drops a transcript that is entirely glossary, so a
  /// correct sentence with the list tacked on survives it. Only the tail is removed.
  ///
  /// Each condition is what keeps a false positive out. An empty glossary leaves the text
  /// untouched. No sentence boundary — including a dot that is not followed by whitespace, as in
  /// `sabaki.dance`, and a transcript with no boundary at all — returns the text unchanged,
  /// because a transcript that is *only* glossary belongs to the other gate ("Joschka SumUp" can
  /// be what the user actually said). The head before the boundary must contain a letter or
  /// digit, so stray punctuation cannot swallow the line. The tail is removed only when every
  /// word is a glossary word, the words' term indices are non-decreasing (an echo keeps glossary
  /// order, so "WhisperShortcut Joschka" stays), and at least two distinct terms appear (a single
  /// "SumUp." is ordinary speech; "Wir nutzen SumUp und lemniscus" has words that are not in the
  /// glossary and stays).
  ///
  /// A *single* term is stripped only when it is exactly one term (a multi-word term such as
  /// "Claude Code" counts as one) and the head holds at least `minHeadWordsForSingleTermEcho`
  /// words. Gemini Flash Lite also appends just one name ("… wie ein 14 Zoll Notebook. Joschka."),
  /// which is the same echo the model was told not to produce. A short head ("Das war's. SumUp.")
  /// or a sign-off ("Viele Grüße. Joschka.") is ordinary speech and stays, and so does the same
  /// term repeated ("Joschka Joschka."), which is not one term occurrence.
  private static let minHeadWordsForSingleTermEcho = 5

  static func strippingTrailingGlossaryEcho(
    _ text: String, glossaryTerms: [String], mode: String
  ) -> String {
    guard !glossaryTerms.isEmpty else { return text }

    var bodyEnd = text.endIndex
    while bodyEnd > text.startIndex {
      let previous = text.index(before: bodyEnd)
      if text[previous].isWhitespace { bodyEnd = previous } else { break }
    }

    // Closing punctuation of the transcript itself, and a quote glued to it (`."`), is not the
    // boundary between the real sentence and the echo.
    let terminalPunctuation: Set<Character> = [".", "!", "?", "…", "\"", "'", "”", "’", "“", "»", "›"]
    var searchEnd = bodyEnd
    while searchEnd > text.startIndex {
      let previous = text.index(before: searchEnd)
      if terminalPunctuation.contains(text[previous]) { searchEnd = previous } else { break }
    }

    // A newline, or sentence punctuation that is immediately followed by whitespace. `sabaki.dance`
    // has a dot with a letter after it, so it is not a boundary. A colon is deliberately not one:
    // "Teilnehmer: Joschka, SumUp" is a dictated list, not an echo.
    let boundaryPunctuation: Set<Character> = [".", "!", "?", "…"]
    var boundary: String.Index?
    var index = text.startIndex
    while index < searchEnd {
      let character = text[index]
      if character.isNewline {
        boundary = index
      } else if boundaryPunctuation.contains(character) {
        let next = text.index(after: index)
        if next < text.endIndex, text[next].isWhitespace {
          boundary = index
        }
      }
      index = text.index(after: index)
    }
    guard let boundary else { return text }

    let headEnd = text.index(after: boundary)
    let head = text[..<headEnd]
    guard head.contains(where: { $0.isLetter || $0.isNumber }) else { return text }

    // First glossary entry that contains the word. Later duplicates do not reorder the echo.
    var termIndexByWord: [String: Int] = [:]
    for (termIndex, term) in glossaryTerms.enumerated() {
      for word in term.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
        let folded = foldForEchoCheck(String(word))
        if termIndexByWord[folded] == nil {
          termIndexByWord[folded] = termIndex
        }
      }
    }

    let tail = text[headEnd..<bodyEnd]
    let tailWords = tail.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map { foldForEchoCheck(String($0)) }

    var distinctTerms = Set<Int>()
    var lastTermIndex: Int?
    for word in tailWords {
      guard let termIndex = termIndexByWord[word] else { return text }
      if let lastTermIndex, termIndex < lastTermIndex { return text }
      lastTermIndex = termIndex
      distinctTerms.insert(termIndex)
    }
    if distinctTerms.count < 2 {
      guard let onlyTerm = distinctTerms.first else { return text }
      let termWordCount = glossaryTerms[onlyTerm]
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
      let headWordCount = head.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
      guard tailWords.count == termWordCount, headWordCount >= minHeadWordsForSingleTermEcho
      else { return text }
    }

    let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    DebugLogger.logWarning("\(mode): Stripped trailing glossary echo \"\(trimmedTail)\"")

    var kept = String(head)
    while let last = kept.last, last.isWhitespace {
      kept.removeLast()
    }
    return kept
  }

  /// Case- and diacritic-insensitive comparison form. Same POSIX fold as the glossary
  /// parse — `.current` made the echo check disagree with it under a Turkish locale.
  private static func foldForEchoCheck(_ word: String) -> String {
    GlossaryDocument.fold(word)
  }

  // MARK: - Mojibake Repair

  /// High-signal markers of UTF-8 bytes that were mis-decoded as Windows-1252/Latin-1 by whatever
  /// app placed the text on the clipboard (e.g. "Ã¤" for "ä", "â€”" for "—"). Real text almost
  /// never contains these sequences.
  private static let mojibakeMarkers = ["Ã", "Â", "â€"]

  private static func mojibakeScore(_ text: String) -> Int {
    mojibakeMarkers.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
  }

  /// Repairs "mojibake" — text whose original UTF-8 bytes were mis-decoded as Windows-1252/Latin-1
  /// upstream (common with pasted terminal/CLI output). The repair re-encodes the mis-decoded
  /// characters back to their original bytes and decodes them as UTF-8. It is applied ONLY when the
  /// tell-tale markers are present AND the round-trip yields strictly fewer markers, so correctly
  /// encoded text — and text the repair can't improve — is returned untouched.
  static func repairMojibakeIfNeeded(_ text: String) -> String {
    let score = mojibakeScore(text)
    guard score > 0 else { return text }
    guard let bytes = text.data(using: .windowsCP1252) ?? text.data(using: .isoLatin1),
          let repaired = String(data: bytes, encoding: .utf8),
          mojibakeScore(repaired) < score else {
      return text
    }
    DebugLogger.log("MOJIBAKE-REPAIR: Fixed pasted text (\(score) markers → \(mojibakeScore(repaired)))")
    return repaired
  }

  // MARK: - Text Validation
  static func validateSpeechText(_ text: String, mode: String = "TRANSCRIPTION-MODE") throws {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Debug logging to see what Whisper actually returned
    DebugLogger.log("VALIDATION: Received text from \(mode) (length: \(trimmedText.count))")
    
    // An empty result means the model heard nothing intelligible (silence, accidental
    // trigger). Surface that as "no speech detected" rather than the misleading "text too
    // short" — with minimumTextLength == 1, empty is in practice the only trigger anyway.
    // Dictate Prompt replies are validated by PromptReplyCleanup, not here.
    if trimmedText.isEmpty {
      ContextLogger.shared.logNoSpeechDetected(
        source: "apiEmptyResult", peakDb: "n/a", durationMs: "n/a", logPrefix: mode)
      throw TranscriptionError.noSpeechDetected
    }
    if trimmedText.count < AppConstants.minimumTextLength {
      throw TranscriptionError.textTooShort
    }
    
    // Enhanced prompt detection - check for various prompt patterns
    let defaultPrompt = AppConstants.defaultTranscriptionSystemPrompt
    let lowercasedText = trimmedText.lowercased()

    // Assistant-mode leakage: on silent/unintelligible audio the Flash-tier model sometimes
    // replies as a chatbot ("Bitte geben Sie mir die Audiodatei, den ich transkribieren soll.")
    // instead of transcribing. These are plausible-length sentences so the length and
    // chars-per-second gates don't catch them; match the request-for-input phrasing directly and
    // surface it as "no speech detected" rather than pasting the refusal into the clipboard.
    if mode.contains("TRANSCRIPTION") {
      let assistantRefusalPhrases = [
        "geben sie mir die audiodatei",
        "gib mir die audiodatei",
        "den ich transkribieren soll",
        "die ich transkribieren soll",
        "text, den ich transkribieren",
        "please provide the audio",
        "provide the audio file",
        "provide the text you",
        "i can transcribe",
      ]
      // Substring matches over a long real transcript false-positive (D11): only treat
      // the recording as a refusal when the whole result is short, or the phrase is
      // the entire text.
      let isShortRefusal = trimmedText.count < 160
      if assistantRefusalPhrases.contains(where: { phrase in
        if lowercasedText == phrase { return true }
        return isShortRefusal && lowercasedText.contains(phrase)
      }) {
        DebugLogger.log("PROMPT-DETECTION: Detected assistant-mode refusal in transcription \(DebugLogger.redacted(trimmedText))")
        throw TranscriptionError.noSpeechDetected
      }
    }
    
    // Check for exact prompt match
    if trimmedText.contains(defaultPrompt) {
      throw TranscriptionError.promptLeakDetected
    }
    
    // Check for partial prompt patterns that might appear in transcription
    let promptKeywords = [
      "convert speech to",
      "clean text with",
      "proper punctuation",
      "transcribe this audio",
      "remove filler words",
      "disfluencies"
    ]
    
    let promptKeywordCount = promptKeywords.filter { lowercasedText.contains($0) }.count
    
    // If more than 2 prompt keywords are found, likely a prompt leak
    if promptKeywordCount > 2 {
      DebugLogger.log("PROMPT-DETECTION: Detected prompt leak in transcription: \(promptKeywordCount) keywords found")
      throw TranscriptionError.promptLeakDetected
    }
    
    // Check for context prefix
    if lowercasedText.hasPrefix("context:") {
      throw TranscriptionError.promptLeakDetected
    }
    
    // Check for system-like responses that might be prompt echoes
    let systemPatterns = [
      "here is the transcription",
      "transcription:",
      "audio transcription:",
      "transcribed text:",
      "the audio says:",
      "the transcription is:"
    ]
    
    let systemPatternCount = systemPatterns.filter { pattern in
      lowercasedText == pattern
        || lowercasedText.hasPrefix(pattern + " ")
        || lowercasedText.hasPrefix(pattern + "\n")
    }.count
    if systemPatternCount > 0 {
      DebugLogger.log("PROMPT-DETECTION: Detected system pattern in transcription: \(systemPatterns.filter { lowercasedText.hasPrefix($0) }.first ?? "unknown")")
      throw TranscriptionError.promptLeakDetected
    }
  }
  
  // Text validation uses AppConstants.minimumTextLength
}

