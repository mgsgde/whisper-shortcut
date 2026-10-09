import Foundation

/// Where Dictate Prompt's "selected text" comes from — decided per recording, never from a generic
/// clipboard read.
///
/// The bug this exists for: the synthetic ⌘C copies nothing when nothing is selected, the pasteboard
/// still holds whatever was copied last, and that text used to reach the model as the selection. In
/// a practice that can be the previous patient's note. So a selection only counts when the
/// pasteboard demonstrably changed for *this* recording; everything else is a compose turn.
///
/// The decisions are pure functions of `NSPasteboard.changeCount` values so they can be tested
/// without a pasteboard, a keystroke, or a frontmost app.
enum DictatePromptSelectionDecision {
  /// Did the synthetic ⌘C copy anything? Only a changed `changeCount` proves it did — an unchanged
  /// one means the pasteboard still holds an older copy that has nothing to do with this recording.
  static func copyProducedSelection(changeCountBefore: Int, changeCountAfter: Int) -> Bool {
    changeCountAfter != changeCountBefore
  }

  /// App Store build with a local model: there is no synthetic ⌘C (it would need Accessibility), so
  /// the user copies first and the clipboard is read as-is. It counts as a selection only when the
  /// pasteboard changed since the last Dictate Prompt run consumed it (or since launch) **and** that
  /// change was not the app's own write — its result copy or its clipboard restore.
  ///
  /// Residual risk, by construction: a copy the user made themselves and then forgot about (say the
  /// previous patient's note, copied by hand into another program) still looks fresh to the next
  /// Dictate Prompt. Nothing on the pasteboard says *why* it was copied; only a real selection read
  /// (⌘C, which this build may not post) could tell.
  static func clipboardIsFreshSelection(
    currentChangeCount: Int, lastConsumedChangeCount: Int, lastOwnWriteChangeCount: Int?
  ) -> Bool {
    guard currentChangeCount != lastConsumedChangeCount else { return false }
    if let lastOwnWriteChangeCount, currentChangeCount == lastOwnWriteChangeCount { return false }
    return true
  }

  /// Copied text as Dictate Prompt uses it: trimmed, nil when nothing is left.
  static func selectionText(from raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

/// The selection captured for one Dictate Prompt recording.
///
/// A reference, created synchronously when the shortcut is pressed and stored on the recording
/// before capture starts. The copied text arrives asynchronously (the synthetic ⌘C is polled for up
/// to `pollDeadline`), so the job awaits `value()` instead of reading the pasteboard itself. That
/// removes the race the Voice Feedback selection accepts: a recording shorter than the copy no
/// longer loses its selection, it just waits the remaining few hundred milliseconds.
/// Thread-safe rather than main-actor-isolated: it is created from the (nonisolated) shortcut
/// handlers and awaited from the job.
final class DictatePromptSelectionCapture: @unchecked Sendable {
  /// Same budget as the Voice Feedback and Glossary copies.
  static let pollDeadline: TimeInterval = 0.5
  static let pollInterval: Duration = .milliseconds(15)

  private let lock = NSLock()
  private var isResolved = false
  private var text: String?
  private var waiters: [CheckedContinuation<String?, Never>] = []

  init() {}

  /// Already decided at creation (the App Store clipboard path).
  static func resolved(_ text: String?) -> DictatePromptSelectionCapture {
    let capture = DictatePromptSelectionCapture()
    capture.resolve(text)
    return capture
  }

  /// First call wins; later calls are ignored so a late poll cannot overwrite the decision.
  func resolve(_ text: String?) {
    let normalized = DictatePromptSelectionDecision.selectionText(from: text)
    lock.lock()
    guard !isResolved else {
      lock.unlock()
      return
    }
    isResolved = true
    self.text = normalized
    let pending = waiters
    waiters = []
    lock.unlock()
    for waiter in pending { waiter.resume(returning: normalized) }
  }

  /// The selected text, or nil for "nothing selected — compose". Suspends only while the copy poll
  /// is still running, which always ends within `pollDeadline`.
  func value() async -> String? {
    await withCheckedContinuation { continuation in
      lock.lock()
      if isResolved {
        let text = self.text
        lock.unlock()
        continuation.resume(returning: text)
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}
