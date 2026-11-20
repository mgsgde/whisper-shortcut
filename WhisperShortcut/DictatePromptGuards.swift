//
//  DictatePromptGuards.swift
//  WhisperShortcut
//
//  Two pure safety checks for Dictate Prompt, which auto-pastes the model's reply over the
//  user's selection: one on the reply, one on the transcribed instruction.
//

import Foundation

/// Decides whether a Dictate Prompt reply may be pasted at all. Deliberately conservative: it
/// only catches replies that cannot be what the user asked for, so a long compose reply or a reply
/// that merely mentions "voice instruction" in a sentence passes.
///
/// Observed: selection "-", a ~400-character spoken list as instruction, and ~11,000 characters of
/// English self-talk back ("The user provided an SRT-like transcript…") that quoted the request
/// scaffold. All of it was pasted into the document. `PromptReplyCleanup.validate` keeps its "no
/// leak heuristics" stance; these two rules are structural, not wording heuristics.
enum PromptReplyGuard {
  enum Verdict: Equatable {
    case ok
    /// The reply quotes one of the app's own request labels at the start of a line.
    case scaffoldEcho
    /// The reply is far longer than anything the selection and instruction could call for.
    case runaway
  }

  /// `instruction` is nil when the spoken instruction is unknown (the history transcription timed
  /// out); the length rule needs it and is skipped, the scaffold rule does not.
  static func verdict(reply: String, selectedText: String?, instruction: String?) -> Verdict {
    // A label the user's own text already has at a line start (editing a document about this app)
    // is not evidence of an echo.
    let userText = [selectedText, instruction].compactMap { $0 }
    if startsLineWithScaffoldLabel(reply), !userText.contains(where: startsLineWithScaffoldLabel) {
      return .scaffoldEcho
    }
    if let instruction {
      let inputLength = (selectedText?.count ?? 0) + instruction.count
      let cap = max(
        AppConstants.promptReplyRunawayMinChars, AppConstants.promptReplyRunawayFactor * inputLength)
      if reply.count > cap { return .runaway }
    }
    return .ok
  }

  static func startsLineWithScaffoldLabel(_ text: String) -> Bool {
    text.split(whereSeparator: \.isNewline).contains { line in
      let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
      return trimmed.hasPrefix(AppConstants.clipboardSelectionLabel)
        || trimmed.hasPrefix(AppConstants.voiceInstructionLabel)
    }
  }
}

/// Checks on a *transcribed* voice instruction, before the model is called. Typed instructions and
/// saved prompts never pass through here.
///
/// Observed instructions that were executed against real selections: "0", "Oh.", a subtitle-shaped
/// hallucination ("00:00:01.077 - 00:00:03.277 …"), and near-misses of a frequent command
/// ("Korriger formulere noe." for "Korrigiere, formuliere neu.").
enum PromptInstructionGuard {
  /// Too little language to be an instruction, or an SRT/VTT-style timestamp where speech should be.
  static func isNotUnderstood(_ instruction: String) -> Bool {
    // Scripts without word spacing carry a whole instruction in one or two characters ("缩短").
    if !instruction.unicodeScalars.contains(where: isUnspacedScript) {
      let letters = instruction.filter(\.isLetter).count
      if letters < AppConstants.instructionMinLetters { return true }
    }
    return instruction.range(
      of: #"^\s*\d{2}:\d{2}:\d{2}[.,]\d{3}"#, options: .regularExpression) != nil
  }

  /// CJK ideograph, kana or hangul.
  private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, 0x31F0...0x31FF,  // hiragana, katakana
      0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F,  // ideographs
      0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:  // hangul
      return true
    default:
      return false
    }
  }

  /// The saved prompt a short transcription is a near-miss of, or nil. Only when exactly one saved
  /// prompt is at least `instructionSnapMinSimilarity` close: zero or several change nothing.
  static func snapped(_ instruction: String, savedPrompts: [String]) -> String? {
    guard instruction.split(whereSeparator: \.isWhitespace).count <= AppConstants.instructionSnapMaxWords
    else { return nil }
    let key = normalizedKey(instruction)
    guard !key.isEmpty else { return nil }
    var matches: [String] = []
    var seen: Set<String> = []
    for raw in savedPrompts {
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      let candidateKey = normalizedKey(text)
      guard !candidateKey.isEmpty, seen.insert(candidateKey).inserted else { continue }
      if similarity(key, candidateKey) >= AppConstants.instructionSnapMinSimilarity - 1e-9 {
        matches.append(text)
      }
    }
    return matches.count == 1 ? matches[0] : nil
  }

  /// Lowercased, punctuation dropped, whitespace collapsed.
  static func normalizedKey(_ text: String) -> String {
    let kept = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
    return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// `1 - editDistance / longerLength`, 1 for equal strings.
  static func similarity(_ a: String, _ b: String) -> Double {
    let x = Array(a), y = Array(b)
    let longer = max(x.count, y.count)
    guard longer > 0 else { return 1 }
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    var previous = Array(0...y.count)
    for i in 1...x.count {
      var row = [i]
      for j in 1...y.count {
        row.append(min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)))
      }
      previous = row
    }
    return 1 - Double(previous[y.count]) / Double(longer)
  }
}
