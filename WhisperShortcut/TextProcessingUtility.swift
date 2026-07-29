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
  
  // MARK: - Text Cleaning
  private static func cleanTranscriptionText(_ text: String) -> String {
    var cleaned = text
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

