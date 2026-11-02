import Foundation

/// Live text while dictating — the pure half (slice S1 of plans/active/live-dictate-preview.md).
///
/// Opt-in, off by default, and only for offline Parakeet: while a Dictate recording runs, a
/// floating panel (`LiveDictatePanel`) shows what has been said so far. It is a **preview**. The
/// text that gets pasted still comes from the single-shot decode of the whole recording after Stop
/// (`plans/active/parakeet-offline.md`, D2), with Glossary boosting and every post-processing step;
/// nothing here feeds into it.
enum LiveDictatePreviewSetting {
  /// The user's toggle in Settings → Dictate. Off unless they turned it on.
  static var isEnabled: Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: UserDefaultsKeys.liveDictatePreview) != nil else {
      return SettingsDefaults.liveDictatePreview
    }
    return defaults.bool(forKey: UserDefaultsKeys.liveDictatePreview)
  }

  /// The preview decodes a 15 s window every few seconds. On the Neural Engine that is a few
  /// percent of one core's worth of work; an Intel Mac would run it on the CPU next to the
  /// recording, so the option is not offered there.
  static var isAppleSilicon: Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
  }

  /// Whether the option can work at all: an Apple Silicon Mac, offline Parakeet as the Dictate
  /// model, and its files on disk. The preview reuses the weights the final decode loads, so an
  /// absent download must never be what a recording start triggers — the same rule
  /// `DictateStreamingSession` follows.
  ///
  /// Pure, with the machine and download state passed in, like `DictateStreamingSession.isEligible`.
  static func isLivePreviewAvailable(
    model: TranscriptionModel, downloaded: Bool, appleSilicon: Bool = isAppleSilicon
  ) -> Bool {
    guard appleSilicon, model.isOffline, model.offlineModelType?.engine == .parakeet else { return false }
    return downloaded
  }

  /// The whole start decision for one recording.
  static func shouldStart(
    enabled: Bool, model: TranscriptionModel, downloaded: Bool, appleSilicon: Bool = isAppleSilicon
  ) -> Bool {
    enabled && isLivePreviewAvailable(model: model, downloaded: downloaded, appleSilicon: appleSilicon)
  }
}

/// Text handling for the panel and the drift log. The text itself is not assembled here: FluidAudio
/// keeps `confirmedTranscript` / `volatileTranscript` with the window seams already repaired from
/// the real token positions (FluidAudio #897) and Glossary replacements applied, which no
/// text-only merge can reproduce. The app reads those two strings and only shapes them for display.
enum LiveDictatePreviewText {
  /// What the panel shows: the end of the text, at most `maxCharacters` long, cut at a word
  /// boundary with a leading ellipsis. Only ~6 lines are visible, and laying out a 5-minute
  /// report on every update would cost more than the window it shows.
  ///
  /// The cut takes from the committed part first, so the dimmed tail is always shown whole.
  static func displayTail(
    committed: String, tentative: String, maxCharacters: Int = 800
  ) -> (committed: String, tentative: String) {
    let committed = normalized(committed)
    let tentative = normalized(tentative)
    let separator = committed.isEmpty || tentative.isEmpty ? 0 : 1
    let overflow = committed.count + separator + tentative.count - maxCharacters
    guard overflow > 0 else { return (committed, tentative) }
    if overflow < committed.count {
      return ("…" + wordAlignedSuffix(of: committed, dropping: overflow), tentative)
    }
    // The tentative tail alone is too long (it rarely is: one or two windows of speech).
    let tentativeOverflow = overflow - committed.count - separator
    return ("", "…" + wordAlignedSuffix(of: tentative, dropping: max(0, tentativeOverflow)))
  }

  /// Word-level difference between the last preview text and the pasted transcript, as counts
  /// only — never the words, since dictations are patient notes. Tells whether the preview is a
  /// fair picture of the result (plan, Design 6). Case and surrounding punctuation are ignored.
  ///
  /// The preview has not decoded the last few seconds before Stop, so a few missing words at the
  /// end are expected; `editDistance` counts them.
  static func drift(preview: String, final: String) -> (previewWords: Int, finalWords: Int, editDistance: Int) {
    let a = words(preview)
    let b = words(final)
    return (a.count, b.count, editDistance(a, b))
  }

  static func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace)
      .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
      .filter { !$0.isEmpty }
  }

  /// Levenshtein distance over words, two rows of memory.
  static func editDistance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
        current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }

  private static func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// `text` without its first `count` characters, moved forward to the next word start.
  private static func wordAlignedSuffix(of text: String, dropping count: Int) -> String {
    let rest = text.dropFirst(count)
    guard let space = rest.firstIndex(of: " ") else { return String(rest) }
    // Already at a word start: keep it.
    if rest.startIndex == text.startIndex || text[text.index(before: rest.startIndex)] == " " {
      return String(rest)
    }
    return String(rest[rest.index(after: space)...])
  }
}
