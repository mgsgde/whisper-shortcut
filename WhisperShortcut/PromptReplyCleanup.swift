//
//  PromptReplyCleanup.swift
//  WhisperShortcut
//
//  Cleanup for Dictate Prompt replies. Transcript leak heuristics do not apply here.
//

import Foundation

/// Dictate Prompt replies are the user's content. The transcript leak heuristics in
/// `TextProcessingUtility` — literal prompt prefixes and suffixes, keyword counts — must not
/// touch them. Those checks cut real answers and reject others.
enum PromptReplyCleanup {

  static func normalize(_ reply: String) -> String {
    TextProcessingUtility.strippingTranscriptionPreamble(
      TextProcessingUtility.normalizingWhitespace(reply))
  }

  /// Empty after trim is a retryable model failure (`emptyModelReply`). Anything shorter than
  /// `AppConstants.minimumTextLength` is `textTooShort`. No leak heuristics.
  static func validate(_ reply: String, mode: String) throws {
    let trimmedText = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedText.isEmpty {
      DebugLogger.logWarning("VALIDATION: \(mode) returned an empty reply — keeping the recording")
      throw TranscriptionError.emptyModelReply
    }
    if trimmedText.count < AppConstants.minimumTextLength {
      throw TranscriptionError.textTooShort
    }
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
          + "through unchanged \(DebugLogger.redacted(trimmed))")
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

}
