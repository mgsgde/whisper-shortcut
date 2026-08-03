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
    let normalized = normalizedLines.joined(separator: "\n")
    
    // Additional cleanup to remove potential prompt remnants
    let cleaned = cleanTranscriptionText(normalized)
    
    return cleaned
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
    DebugLogger.log("PROMPT-CLEANUP: Removed model preamble '\(text[stripped].trimmingCharacters(in: .whitespacesAndNewlines))'")
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
      "transcription:",
      "audio transcription:",
      "here is the transcription:",
      "the transcription is:",
      "transcribed text:",
      "the audio says:"
    ]
    
    let lowercasedText = cleaned.lowercased()
    for prefix in promptPrefixes {
      if lowercasedText.hasPrefix(prefix) {
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
      if lowercasedText.hasSuffix(suffix) {
        DebugLogger.log("PROMPT-CLEANUP: Removed suffix: '\(suffix)' from transcription")
        cleaned = String(cleaned.dropLast(suffix.count))
        break
      }
    }
    
    // Clean up any remaining whitespace
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if cleaned.count != originalLength {
      DebugLogger.log("PROMPT-CLEANUP: Text cleaned: \(originalLength) -> \(cleaned.count) characters")
    }
    
    return cleaned
  }
  
  // MARK: - JSON-Wrapped Edit Responses

  /// Unwraps a Dictate Prompt reply that came back as a JSON edit object instead of plain text.
  ///
  /// `gpt-audio-1.5` intermittently answers an editing instruction with structured output —
  /// measured at roughly 20–30% of "make this shorter" requests, reproduced across three separate
  /// benchmark runs (2026-08-02), in shapes like:
  ///
  ///     {"text": "…"}
  ///     {"edit_type": "shorten", "text": "…"}
  ///     {"edits": [{"find": "…", "replacement": "…"}]}
  ///
  /// Without this, that JSON is what gets pasted into the user's document. The system prompt
  /// already forbids it; this is the backstop for when the model does it anyway.
  ///
  /// Deliberately conservative — it must never mangle a legitimate answer:
  /// - Only fires when the **entire** response parses as a JSON object. Prose that merely
  ///   contains braces is left alone, as is a user asking for JSON output (that arrives as an
  ///   array or as text around the braces, not as a bare object).
  /// - Only unwraps shapes it fully understands. An `edits` array is applied against
  ///   `selectedText`, and only when *every* `find` string actually occurs in it; a single
  ///   unmatched fragment aborts the whole rewrite.
  /// - A bail-out on text it does not recognise returns the input unchanged, so the worst case is
  ///   the behaviour before this existed. The one exception is an `edits` array it cannot apply:
  ///   that is unmistakably our own protocol, never something the user asked for, so the selection
  ///   comes back untouched instead — see `abandoningUnapplicableEdits`.
  static func unwrappingJSONEditResponse(_ text: String, selectedText: String?) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
          let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return text }

    // Shape 1: a string field carrying the finished text. Two passes, because neither rule alone
    // is safe:
    //
    // 1. Exact well-known names win outright. `{"edit_type": "shorten", "text": "…"}` is a real
    //    reply, and a name-shape match alone would happily return the label "shorten" from
    //    `edit_type` — a regression the test suite caught.
    // 2. Otherwise fall back to matching the *shape* of the key, because the name varies per
    //    response (`text`, `edited_text`, `final_text` all observed from the same model) and an
    //    exact list is outgrown by the next reply. Metadata-ish names are excluded, and the
    //    longest value wins, since a label is short and the edited text is not.
    //
    // Requiring the token to appear in the key at all is what keeps a genuine one-field config
    // object like {"host": "localhost"} from being unwrapped into its value.
    func unwrapped(_ key: String) -> String? {
      guard let value = object[key] as? String,
            !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
      DebugLogger.log("PROMPT-JSON-UNWRAP: unwrapped '\(key)' field (\(value.count) chars)")
      return value
    }

    for key in ["text", "edited_text", "final_text", "result", "output", "content", "edited"] {
      if let value = unwrapped(key) { return value }
    }

    let textualKeyTokens = ["text", "result", "output", "content", "edit", "final", "response"]
    let metadataKeyTokens = ["type", "kind", "action", "operation", "mode", "reason"]
    let candidate = object.keys
      .filter { key in
        let lowered = key.lowercased()
        return textualKeyTokens.contains { lowered.contains($0) }
          && !metadataKeyTokens.contains { lowered.contains($0) }
      }
      .compactMap { key -> (String, String)? in
        guard let value = object[key] as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (key, value)
      }
      // Longest value first; key name as the tie-break so the result is deterministic.
      .sorted { ($0.1.count, $1.0) > ($1.1.count, $0.0) }
      .first
    if let candidate { return unwrapped(candidate.0) ?? text }

    let selectionOrNil = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)

    // Shape 2a: `{"edits": ["the whole rewritten text"]}` — the array holds bare strings rather
    // than edit objects. Only a single entry is salvageable; several would need to be stitched
    // back into the selection, and there is nothing saying where.
    if let plainEdits = object["edits"] as? [String], plainEdits.count == 1,
       case let candidate = plainEdits[0].trimmingCharacters(in: .whitespacesAndNewlines),
       !candidate.isEmpty,
       candidate.count >= (selectionOrNil?.count ?? 0) / 2 {
      DebugLogger.log("PROMPT-JSON-UNWRAP: unwrapped a single bare-string edit (\(candidate.count) chars)")
      return candidate
    }

    // Shape 2b: find/replace instructions to apply to the selection.
    guard let edits = object["edits"] as? [[String: Any]], !edits.isEmpty,
          let selection = selectionOrNil, !selection.isEmpty
    else {
      DebugLogger.logError(
        "PROMPT-JSON-UNWRAP: response is a JSON object but no known shape matched — passing it "
          + "through unchanged: \(trimmed.prefix(160))")
      return text
    }

    var result = selection
    for edit in edits {
      let find = (edit["find"] as? String) ?? (edit["original"] as? String)
      let replacement = Self.replacementText(in: edit)
      guard let find, let replacement, result.contains(find) else {
        return Self.wholeSpanRewrite(edits: edits, selection: selection)
          ?? Self.abandoningUnapplicableEdits(selection: selection)
      }
      result = result.replacingOccurrences(of: find, with: replacement)
    }
    DebugLogger.log("PROMPT-JSON-UNWRAP: applied \(edits.count) edit(s) to the selection")
    return result
  }

  /// What to paste when the reply is unmistakably our own edit protocol but no reading of it
  /// applies: the selection, unchanged.
  ///
  /// This used to return the raw reply so "the user sees something is off". Measured on
  /// 2026-08-03, `gpt-audio-1.5` emitted `{"edits": [{"start": 40, "end": 44, "replacement":
  /// "am"}]}` — a short index-based replacement that `wholeSpanRewrite` correctly refuses — and
  /// that whole string is what would have replaced the user's paragraph. Both readings tell the
  /// user the edit failed; only one of them destroys the text they had selected. Offsets are still
  /// not honoured (see `wholeSpanRewrite`: an observed `end` was 41 characters short), so the
  /// no-op is the best available outcome.
  ///
  /// Only reachable once an `edits` array has been found, i.e. never for JSON the user asked for.
  private static func abandoningUnapplicableEdits(selection: String) -> String {
    DebugLogger.logError(
      "PROMPT-JSON-UNWRAP: edit entry did not apply cleanly — leaving the selection untouched "
        + "rather than pasting the protocol JSON over it")
    return selection
  }

  private static func replacementText(in edit: [String: Any]) -> String? {
    (edit["replacement"] as? String) ?? (edit["new"] as? String) ?? (edit["text"] as? String)
  }

  /// Last-resort reading of an `edits` array that cannot be applied literally.
  ///
  /// The model also emits index-based edits (`{"start": 0, "end": 178, "replacement": "…"}`) and
  /// bare strings (`{"edits": ["…"]}`). Character offsets produced by an LLM do not survive
  /// arithmetic — the observed `end` was 41 characters short of the selection, so honouring it
  /// would have glued a fragment of the original onto the rewrite. So offsets are ignored and
  /// only one narrow case is salvaged: a **single** edit whose replacement is long enough to be
  /// the whole rewritten text rather than a fragment of it. Instructions like "make this shorter"
  /// land here, and they are exactly the ones where the replacement *is* the answer.
  ///
  /// Anything else returns nil, and the caller passes the raw reply through untouched.
  private static func wholeSpanRewrite(edits: [[String: Any]], selection: String) -> String? {
    guard edits.count == 1, let replacement = replacementText(in: edits[0]) else { return nil }
    let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    // A fragment replacement cannot be the finished text; returning it would silently delete
    // everything around it. Half the selection is the line between the two readings.
    guard trimmed.count >= selection.count / 2 else { return nil }
    DebugLogger.log(
      "PROMPT-JSON-UNWRAP: single edit could not be located in the selection; using its "
        + "replacement as the full rewrite (\(trimmed.count) chars vs \(selection.count) selected)")
    return trimmed
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
      "\(mode): Discarding implausible transcript (\(text.count) chars from \(String(format: "%.1f", audioDurationSeconds))s audio, max plausible \(maxPlausibleCharacters)): '\(text.prefix(120))'"
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
  static func discardingGlossaryEchoTranscript(
    _ text: String, audioDurationSeconds: Double, glossaryTerms: [String], mode: String
  ) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, audioDurationSeconds > 0, !glossaryTerms.isEmpty else { return text }

    // Real speech runs 10–20 chars/s; even slow, pause-heavy dictation stays above 5. Three
    // chars/s is far enough below that floor that only near-empty output trips it.
    let minPlausibleCharacters = audioDurationSeconds * 3.0
    guard Double(trimmed.count) < minPlausibleCharacters else { return text }

    // Content test: every word in the transcript is a glossary term. Split on anything that
    // isn't a letter or digit so `sabaki.dance`, `Sabaki-Dance` and `Sabaki, Dance` all reduce
    // to the same two words.
    let folded = Set(glossaryTerms.flatMap { term in
      term.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map { foldForEchoCheck(String($0)) }
    })
    let words = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map { foldForEchoCheck(String($0)) }
    guard !words.isEmpty, words.allSatisfy({ folded.contains($0) }) else { return text }

    DebugLogger.logError(
      "\(mode): Discarding glossary-echo transcript (\(trimmed.count) chars from \(String(format: "%.1f", audioDurationSeconds))s audio, min plausible \(String(format: "%.0f", minPlausibleCharacters)), all words are glossary terms): '\(trimmed.prefix(120))'"
    )
    return ""
  }

  /// Case- and diacritic-insensitive comparison form, matching `SpeechService.foldGlossaryTerm`.
  private static func foldForEchoCheck(_ word: String) -> String {
    word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
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
    DebugLogger.log("VALIDATION: Received text from \(mode) (length: \(trimmedText.count)): '\(trimmedText)'")
    
    // An empty result means the model heard nothing intelligible (silence, accidental
    // trigger). Surface that as "no speech detected" rather than the misleading "text too
    // short" — with minimumTextLength == 1, empty is in practice the only trigger anyway.
    if trimmedText.isEmpty {
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
      if assistantRefusalPhrases.contains(where: { lowercasedText.contains($0) }) {
        DebugLogger.log("PROMPT-DETECTION: Detected assistant-mode refusal in transcription: '\(trimmedText.prefix(80))'")
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
    if trimmedText.hasPrefix("context:") {
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
    
    let systemPatternCount = systemPatterns.filter { lowercasedText.hasPrefix($0) }.count
    if systemPatternCount > 0 {
      DebugLogger.log("PROMPT-DETECTION: Detected system pattern in transcription: \(systemPatterns.filter { lowercasedText.hasPrefix($0) }.first ?? "unknown")")
      throw TranscriptionError.promptLeakDetected
    }
  }
  
  // Text validation uses AppConstants.minimumTextLength
}

