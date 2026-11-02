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

  /// Whether the option can work at all: the Dictate model is offline Parakeet and its files are
  /// on disk. The preview reuses the weights the final decode loads, so an absent download must
  /// never be what a recording start triggers — the same rule `DictateStreamingSession` follows.
  ///
  /// Pure, with the download state passed in, like `DictateStreamingSession.isEligible`.
  static func isLivePreviewAvailable(model: TranscriptionModel, downloaded: Bool) -> Bool {
    guard model.isOffline, model.offlineModelType?.engine == .parakeet else { return false }
    return downloaded
  }

  /// The whole start decision for one recording.
  static func shouldStart(enabled: Bool, model: TranscriptionModel, downloaded: Bool) -> Bool {
    enabled && isLivePreviewAvailable(model: model, downloaded: downloaded)
  }
}

/// Turns FluidAudio's stream of sliding-window hypotheses into the two pieces the panel shows:
/// `committed` text (normal colour) and the still-changing `tentative` tail (dimmed).
///
/// Each window carries the text of its *new* audio. Two things make a naive append repeat words
/// at the seams, and this type removes both:
///
/// - The engine re-decodes the previous window's last word in full at the start of the next
///   window (FluidAudio #897) and retires it from its own transcript, but the update stream does
///   not say so. The next window therefore usually starts with that word again.
/// - The re-decode can come back longer (`Pat` → `Patienten`) when the previous window cut the
///   word off.
///
/// So the leading words of a window that repeat the end of the text so far (compared without case
/// and punctuation) **replace** those words — the newer decode had right-hand context and has the
/// better punctuation — and a first word that extends the last word replaces it.
///
/// Confirmation mirrors the engine's own two-tier state: a confirmed window promotes the current
/// tentative tail to committed and becomes the new tail; an unconfirmed window extends the tail.
///
/// Pure value type; no FluidAudio types, so it is unit-tested directly.
struct LiveTranscriptMerger: Equatable {
  private(set) var committed: [String] = []
  private(set) var tentative: [String] = []

  /// Longest run of words a window may repeat from the text before it. The engine re-emits one
  /// word; a few more cover a re-segmented boundary without letting a genuine repeated phrase far
  /// back be mistaken for overlap.
  static let maxOverlapWords = 8

  var committedText: String { committed.joined(separator: " ") }
  var tentativeText: String { tentative.joined(separator: " ") }
  var isEmpty: Bool { committed.isEmpty && tentative.isEmpty }

  mutating func ingest(_ text: String, isConfirmed: Bool) {
    let incoming = text.split(whereSeparator: \.isWhitespace).map(String.init)
    retire(Self.wordsToRetire(existingTail: Array((committed + tentative).suffix(Self.maxOverlapWords)), incoming: incoming))
    if isConfirmed {
      committed.append(contentsOf: tentative)
      tentative = incoming
    } else {
      tentative.append(contentsOf: incoming)
    }
  }

  /// How many trailing words of the text so far the incoming window replaces.
  static func wordsToRetire(existingTail: [String], incoming: [String]) -> Int {
    guard !existingTail.isEmpty, !incoming.isEmpty else { return 0 }
    let maxK = min(maxOverlapWords, existingTail.count, incoming.count)
    for k in stride(from: maxK, through: 1, by: -1) {
      let tail = existingTail.suffix(k).map(fold)
      let head = incoming.prefix(k).map(fold)
      if tail == head, tail.contains(where: { !$0.isEmpty }) { return k }
    }
    // The re-decoded last word came back longer than the cut-off version.
    let last = fold(existingTail[existingTail.count - 1])
    let first = fold(incoming[0])
    if !last.isEmpty, first.count > last.count, first.hasPrefix(last) { return 1 }
    return 0
  }

  /// Removes `count` words from the end, tentative first.
  private mutating func retire(_ count: Int) {
    var remaining = count
    let fromTentative = min(remaining, tentative.count)
    tentative.removeLast(fromTentative)
    remaining -= fromTentative
    committed.removeLast(min(remaining, committed.count))
  }

  /// A word as compared at the seams: no case, no surrounding punctuation.
  static func fold(_ word: String) -> String {
    word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
  }
}
