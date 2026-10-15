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

  /// Whether a Dictate Prompt turn must be refused because it edits a selection that isn't there:
  /// nothing selected, no screenshot standing in for the selection, and the instruction is an edit
  /// quick action or only a bare edit command. The timeout placeholder is not judged.
  static func refusesEditWithoutSelection(
    hasSelection: Bool, hadScreenshot: Bool, instruction: String, isEditQuickAction: Bool
  ) -> Bool {
    !hasSelection && !hadScreenshot
      && instruction != SpeechService.voiceInstructionPlaceholder
      && (isEditQuickAction || isBareEditCommand(instruction))
  }

  /// True when the instruction is only an edit command ("Korrigiere", "Rephrase this") and
  /// nothing else. A compose turn with one of these used to let the model invent the text it
  /// was "editing". Extra words ("Korrigiere, mein Geburtsdatum ist 15.08.91", "schreib eine
  /// Notiz") are a real compose request and return false.
  static func isBareEditCommand(_ instruction: String) -> Bool {
    var text = instruction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while let last = text.last, last == "." || last == "!" || last == "?" {
      text.removeLast()
    }
    text = strippingLeadingFiller(text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !text.isEmpty else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return bareEditCommandRegex.firstMatch(in: text, range: range) != nil
  }

  /// "Ähm, korrigiere" is the same command as "korrigiere". One leading filler only, and only
  /// when it is its own word — "ähmlich" must stay intact.
  private static func strippingLeadingFiller(_ text: String) -> String {
    let fillers = ["ähm", "äh", "hm"]
    for filler in fillers {
      guard text.hasPrefix(filler) else { continue }
      var rest = text.dropFirst(filler.count)
      if rest.first == "," {
        rest = rest.dropFirst()
      } else if let first = rest.first, !first.isWhitespace {
        continue
      }
      return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
  }

  /// The whole instruction, after normalization, must be one of these and nothing more.
  /// Optional words sit inside the group so "kürze" matches and "kürze das" does too, without
  /// a trailing space being required.
  private static let bareEditCommandRegex: NSRegularExpression = {
    let pattern =
      "^(?:korrigiere|korrigier das|korrigieren|formuliere(?: das)? (?:neu|um)|schreib(?: das)? um|umschreiben|kürzer|kürze(?: das)?|mach (?:es|das) kürzer|verbessere(?: das)?|correct(?: this| that)?|fix (?:this|that|it)|rephrase(?: this| that)?|shorten(?: this| that)?|make (?:it|this) shorter|proofread(?: this)?)$"
    return try! NSRegularExpression(pattern: pattern)
  }()
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
  /// How long to keep watching the pasteboard after ⌘C once the poll has already given up.
  /// Logging only: a copy that arrives in this window is still a compose turn.
  static let lateCopyWatch: TimeInterval = 2.0
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
