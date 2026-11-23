import Foundation

/// One Dictate Live recording: pieces in (rotated chunk files, in order), text at the cursor out.
///
/// With `decodesConcurrently` false (offline Parakeet) each piece is decoded inside the serial
/// chain, which is today's behaviour. With it true (a cloud model) the decode starts immediately,
/// off the main actor and concurrently with the other pieces, and the chain only waits for that
/// piece's result before inserting it. Either way the text lands in `add` order. Decoding and
/// inserting are passed in, which keeps this type free of AppKit and testable with fakes:
///
/// - `decode` turns a chunk file into text ("" for no speech). In the app: the normal transcription
///   path — Parakeet or the selected cloud model.
/// - `insert` puts text at the cursor and returns false when it must not right now — the app the
///   user dictated into is not in front. That text is **held**, never typed into another app (it
///   could be another patient's record), and goes in with the next piece, on `retryHeld()` when the
///   app comes back, or is handed back by `finish` for the clipboard.
///
/// A piece that fails to decode is skipped and counted; `finish` reports the count so the caller can
/// fall back to a whole-file decode instead of leaving a silent gap in the document.
///
/// Threading: `add`, `retryHeld` and `cancel` are called on the main thread; all state is read and
/// written on the main actor.
final class LiveDictationSession {
  typealias Decode = (URL) async throws -> String
  typealias Insert = @MainActor (String) async -> Bool

  struct Outcome: Equatable {
    /// Everything the dictation produced, joined — what the document should now contain.
    let text: String
    /// The part that could not be inserted because another app was in front.
    let heldText: String
    let pieces: Int
    let failedPieces: Int
  }

  private let decode: Decode
  private let insert: Insert
  private let decodesConcurrently: Bool
  private var joiner = LiveChunkJoiner()
  private var pending = ""
  private var chain: Task<Void, Never>?
  /// Cloud decodes started in `add`, so `cancel()` can stop them. Empty when decoding is serial.
  private var decodeTasks: [Task<(String, Int), Error>] = []
  private var anyPieceAdded = false
  private var pieces = 0
  private var failedPieces = 0
  private var isCancelled = false
  /// When this recording began, before the first piece was decoded.
  let startedAt = Date()

  /// `holdsPeriods` is false in "Only when spoken" mode: every period there was said on purpose,
  /// so `LiveChunkJoiner` must never hold one back waiting to see whether the sentence continues.
  /// `caret` is the character already before the cursor. `.unknown` spaces the first piece as today.
  /// `decodesConcurrently` is true for a cloud model: each piece starts decoding in `add`, and the
  /// chain inserts the results in `add` order. False (the default) decodes inside the chain, which
  /// is the offline Parakeet path.
  init(
    decode: @escaping Decode, insert: @escaping Insert, holdsPeriods: Bool = true,
    caret: FocusedTextContext.CaretContext = .unknown, decodesConcurrently: Bool = false
  ) {
    self.decode = decode
    self.insert = insert
    self.decodesConcurrently = decodesConcurrently
    joiner.holdsPeriods = holdsPeriods
    joiner.seed(caret)
  }

  /// A rotated chunk (mid-recording) or the tail chunk (at stop). Silent chunks are skipped.
  func add(_ url: URL, isSilent: Bool) {
    guard !isCancelled else { return }
    anyPieceAdded = true
    guard !isSilent else {
      DebugLogger.log("LIVE-DICTATE: Silent piece skipped (\(url.lastPathComponent))")
      return
    }
    if decodesConcurrently {
      // `add` is nonisolated, so this task is not on the main actor. The chain below only waits
      // for the result and inserts it, in the order `add` was called.
      let decode = self.decode
      let task = Task { () throws -> (String, Int) in
        let started = Date()
        let text = try await decode(url)
        return (text, Int(Date().timeIntervalSince(started) * 1000))
      }
      decodeTasks.append(task)
      enqueue { session in
        await session.process { try await task.value }
      }
    } else {
      enqueue { session in
        await session.process {
          let started = Date()
          let text = try await session.decode(url)
          return (text, Int(Date().timeIntervalSince(started) * 1000))
        }
      }
    }
  }

  /// The app the user dictated into may be in front again: try to insert held text.
  func retryHeld() {
    guard !isCancelled, !pending.isEmpty else { return }
    enqueue { session in await session.flush() }
  }

  /// Decodes and inserts what is left, then reports the whole dictation. `deliveredAudio` is the
  /// recorder's final file: when the recording never rotated (a short dictation), it is the only
  /// piece; otherwise the tail already arrived through `add`. Throws `CancellationError` after
  /// `cancel()`.
  @MainActor
  func finish(deliveredAudio: URL) async throws -> Outcome {
    if !anyPieceAdded { add(deliveredAudio, isSilent: false) }
    // The held-back period goes through the same chain as everything else, so a `retryHeld` from
    // an app activation can never flush the same text a second time.
    enqueue { session in
      let tail = session.joiner.finish()
      guard !tail.isEmpty else { return }
      session.pending += tail
      await session.flush()
    }
    await drain()
    if isCancelled { throw CancellationError() }
    let outcome = Outcome(
      text: joiner.inserted, heldText: pending, pieces: pieces, failedPieces: failedPieces)
    DebugLogger.log(
      "LIVE-DICTATE: finished pieces=\(pieces) failed=\(failedPieces) chars=\(outcome.text.count) "
        + "heldChars=\(pending.count) durationS=\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))")
    return outcome
  }

  /// Stops decoding and inserting. Text already inserted stays where it is — it is in another app.
  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    chain?.cancel()
    for task in decodeTasks { task.cancel() }
    decodeTasks.removeAll()
    DebugLogger.log("LIVE-DICTATE: Session cancelled after \(pieces) piece(s); inserted text stays")
  }

  // MARK: - Chain

  /// Waits until every step queued so far — and any queued while waiting — has run.
  @MainActor
  func drain() async {
    while true {
      let current = chain
      await current?.value
      if current == chain { return }
    }
  }

  private func enqueue(_ step: @escaping @MainActor (LiveDictationSession) async -> Void) {
    let previous = chain
    chain = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !self.isCancelled else { return }
      await step(self)
    }
  }

  /// `decode` returns the piece text and how long the decode itself took. In concurrent mode that
  /// duration was measured inside the decode task, from its start to its result; serially it is
  /// measured around the call, which runs only once the chain reaches this piece.
  @MainActor
  private func process(decode: @MainActor () async throws -> (String, Int)) async {
    pieces += 1
    let index = pieces
    let text: String
    let decodeMs: Int
    do {
      (text, decodeMs) = try await decode()
    } catch {
      if isCancelled || error is CancellationError { return }
      failedPieces += 1
      DebugLogger.logWarning(
        "LIVE-DICTATE: Piece \(index) failed to decode (\(String(describing: error))); the whole-file fallback will cover it")
      return
    }
    guard !isCancelled else { return }
    let piece = joiner.next(text)
    pending += piece
    DebugLogger.log("LIVE-DICTATE: Piece \(index) decodeMs=\(decodeMs) chars=\(piece.count)")
    await flush()
  }

  @MainActor
  private func flush() async {
    guard !pending.isEmpty, !isCancelled else { return }
    let text = pending
    if await insert(text) {
      // Only what was handed to `insert`. The chain is serial, so `pending` still starts with it;
      // checked anyway, because a crash here would cost the user the whole dictation.
      if pending.hasPrefix(text) {
        pending.removeFirst(text.count)
      } else {
        pending = ""
      }
    } else {
      DebugLogger.log("LIVE-DICTATE: Holding \(pending.count) chars — the dictated-into app is not in front")
    }
  }
}
