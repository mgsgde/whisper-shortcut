//
//  SpeechTextSanitizer.swift
//  WhisperShortcut
//
//  Turns Markdown-formatted text into something worth listening to, for Read Aloud.
//

import Foundation

/// Strips Markdown syntax and URLs from text on its way to a TTS model.
///
/// The chat Read Aloud button hands over the reply's raw Markdown *source*, and the chat path
/// deliberately skips Smart Rewrite (LLM prose needs no rewriting), so nothing else ever removed
/// the syntax: a real request went out carrying `strategy.[[1]](https://samoburja.com/)` and
/// `humanism.[[2]](https://x.com/SamoBurja/status/2080…`. Whether a given model voices a URL,
/// spells it out, or silently skips it is unspecified — and either way we pay synthesis time for
/// characters no listener wants. Roughly 15–20 % of a citation-heavy reply is this noise.
///
/// Deliberately lossy where speech demands it: fenced code blocks and images are dropped rather
/// than voiced, and citation markers (`[1]`) disappear instead of becoming a spoken "one".
enum SpeechTextSanitizer {

  /// Order matters throughout: images before links (an image is a link with a `!`), fenced code
  /// before inline code, and link-unwrapping before bare-URL removal — otherwise the URL inside
  /// `[text](url)` is deleted first and the leftover `[text]()` no longer matches the link
  /// pattern.
  static func plainSpeech(from markdown: String) -> String {
    var text = markdown

    // Fenced code blocks — unspeakable, and often longer than the prose around them.
    text = replacing(text, #"(?m)^[ \t]*```[\s\S]*?```[ \t]*$"#, with: "")
    // Unterminated final fence (streamed replies get cut off mid-block).
    text = replacing(text, #"(?m)^[ \t]*```[\s\S]*$"#, with: "")

    // Images: no spoken equivalent, and alt text is usually a filename.
    text = replacing(text, #"!\[[^\]]*\]\([^)]*\)"#, with: "")

    // Citation-style links whose label is just a number — `[[1]](url)` or `[1](url)`. Voicing
    // these injects stray digits into the middle of sentences.
    text = replacing(text, #"\[{1,2}\s*\d+\s*\]{1,2}\([^)]*\)"#, with: "")
    // Remaining inline links and reference links: keep the label, drop the target.
    text = replacing(text, #"\[([^\]]*)\]\([^)]*\)"#, with: "$1")
    text = replacing(text, #"\[([^\]]*)\]\[[^\]]*\]"#, with: "$1")
    // Bare citation markers left behind by a source list (`[1] samoburja.com`).
    text = replacing(text, #"\[{1,2}\s*\d+\s*\]{1,2}"#, with: "")
    // Autolinks and bare URLs.
    text = replacing(text, #"<(?:https?|mailto):[^>]*>"#, with: "")
    text = replacing(text, #"\b(?:https?://|www\.)\S+"#, with: "")

    // Inline code and emphasis: keep the content, drop the markers. `**` before `*` so bold
    // isn't shredded into two stray asterisks.
    text = replacing(text, "`([^`]*)`", with: "$1")
    text = replacing(text, #"\*\*([^*]+)\*\*"#, with: "$1")
    text = replacing(text, #"__([^_]+)__"#, with: "$1")
    text = replacing(text, #"\*([^*\n]+)\*"#, with: "$1")
    text = replacing(text, #"(?<![\w])_([^_\n]+)_(?![\w])"#, with: "$1")
    text = replacing(text, #"~~([^~]+)~~"#, with: "$1")

    // Block-level markers. Headings, blockquotes and list bullets carry structure a listener
    // hears as a pause anyway, so the marker itself is pure noise.
    text = replacing(text, #"(?m)^[ \t]*#{1,6}[ \t]+"#, with: "")
    text = replacing(text, #"(?m)^[ \t]*>[ \t]?"#, with: "")
    text = replacing(text, #"(?m)^[ \t]*[-*+•][ \t]+"#, with: "")
    text = replacing(text, #"(?m)^[ \t]*\d+[.)][ \t]+"#, with: "")
    // Horizontal rules and table separator rows (`|---|:--:|`).
    text = replacing(text, #"(?m)^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, with: "")
    text = replacing(text, #"(?m)^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(\|[ \t]*:?-{2,}:?[ \t]*)*\|?[ \t]*$"#, with: "")
    // Remaining table cell separators become sentence-internal pauses.
    text = replacing(text, #"(?m)^[ \t]*\|[ \t]*"#, with: "")
    text = replacing(text, #"[ \t]*\|[ \t]*$"#, with: "")
    text = replacing(text, #"[ \t]*\|[ \t]*"#, with: ", ")

    // Collapse the gaps everything above left behind.
    text = replacing(text, #"[ \t]{2,}"#, with: " ")
    text = replacing(text, #"(?m)[ \t]+$"#, with: "")
    text = replacing(text, #"\n{3,}"#, with: "\n\n")
    // A line reduced to leftover punctuation (e.g. a source list that was all links).
    text = replacing(text, #"(?m)^[ \t]*[,.;:]+[ \t]*$"#, with: "")
    text = replacing(text, #"\n{3,}"#, with: "\n\n")

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replacing(_ text: String, _ pattern: String, with template: String) -> String {
    text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
  }
}
