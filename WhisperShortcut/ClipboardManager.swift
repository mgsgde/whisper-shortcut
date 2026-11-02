import AppKit
import Foundation

/// What the pasteboard held before the app overwrote it, so a paste can put it back.
/// Every item and representation is copied eagerly — `NSPasteboardItem`s belonging to the
/// general pasteboard are invalidated by the next `clearContents()`, so holding references
/// to them would restore nothing.
struct ClipboardSnapshot {
  fileprivate let items: [[NSPasteboard.PasteboardType: Data]]

  var isEmpty: Bool { items.allSatisfy { $0.isEmpty } }
}

class ClipboardManager {
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  /// Pasteboard contents captured before this job clobbered them. Set at the first write of
  /// a job (the synthetic ⌘C of Dictate Prompt, or the result copy) and consumed once the
  /// synthetic ⌘V has landed. Only used when "Restore clipboard" is on.
  private var pendingRestore: ClipboardSnapshot?
  /// `changeCount` immediately after the last `copyToClipboard` write. Restore is skipped
  /// if the pasteboard changed in the meantime (user ⌘C, another dictation).
  private var changeCountAfterLastWrite: Int = 0
  /// `changeCount` right after the selection copy (Dictate Prompt's synthetic ⌘C) that followed
  /// the restore point. The job's own result copy is the next write; if the pasteboard moved
  /// before it, the user copied something while the job ran and the restore point is stale.
  private var changeCountAfterSelectionCopy: Int?
  /// `changeCount` right after the app's own most recent pasteboard write (a result copy or a
  /// clipboard restore). Unlike `changeCountAfterLastWrite` it is never reset, because its job is
  /// different: it lets Dictate Prompt tell "the user copied something" from "the pasteboard still
  /// holds what we put there" (`DictatePromptSelectionDecision.clipboardIsFreshSelection`).
  private(set) var lastOwnWriteChangeCount: Int?

  // MARK: - Constants
  private enum Constants {
    static let maxPreviewLength = 50
    static let defaultSeparator = "\n"
    static let punctuation: Set<Character> = [".", "!", "?", ":", ";"]
  }

  func copyToClipboard(text: String) {
    if let expected = changeCountAfterSelectionCopy, pasteboard.changeCount != expected {
      DebugLogger.log("AUTO-PASTE: Dropping clipboard restore point — user copied during processing")
      pendingRestore = nil
    }
    changeCountAfterSelectionCopy = nil
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    changeCountAfterLastWrite = pasteboard.changeCount
    lastOwnWriteChangeCount = pasteboard.changeCount
  }

  /// Marker types from nspasteboard.org: clipboard managers and history apps (Maccy, Raycast,
  /// Paste, …) skip content that carries them.
  private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
  private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

  /// One Dictate Live piece, written only so the synthetic ⌘V can paste it. Marked transient and
  /// concealed, and kept to this Mac (no Universal Clipboard to the phone): these are fragments of
  /// patient notes passing through, not something the user copied.
  func copyLivePiece(text: String) {
    _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
    pasteboard.setString(text, forType: .string)
    pasteboard.setData(Data(), forType: Self.transientType)
    pasteboard.setData(Data(), forType: Self.concealedType)
    changeCountAfterLastWrite = pasteboard.changeCount
    lastOwnWriteChangeCount = pasteboard.changeCount
  }

  /// Puts `snapshot` back, unless something other than this app wrote to the pasteboard after
  /// our last write (the user copied something meanwhile — that wins).
  @discardableResult
  func restore(_ snapshot: ClipboardSnapshot) -> Bool {
    guard pasteboard.changeCount == lastOwnWriteChangeCount else {
      DebugLogger.log("CLIPBOARD: Skipping restore — pasteboard changed since our last write")
      return false
    }
    return write(snapshot)
  }

  /// Copies dictation transcript text with capitalization and trailing punctuation.
  func copyTranscriptionToClipboard(text: String, addTrailingPeriod: Bool = true) {
    copyToClipboard(text: formatTranscription(text, addTrailingPeriod: addTrailingPeriod))
  }

  func getClipboardText() -> String? {
    return pasteboard.string(forType: .string)
  }

  // MARK: - Non-destructive paste

  /// Copies every item currently on the pasteboard, including non-text flavors, so it can be
  /// put back after auto-paste.
  func snapshot() -> ClipboardSnapshot {
    let items = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
        result[type] = item.data(forType: type)
      }
    }
    return ClipboardSnapshot(items: items)
  }

  /// Remembers the current contents for a later `restorePendingSnapshot()`, unless this job
  /// already captured a restore point (Dictate Prompt clobbers the pasteboard twice: once
  /// with the synthetic ⌘C, once with the result — only the first snapshot is the user's).
  func captureRestorePointIfNeeded() {
    guard pendingRestore == nil else { return }
    pendingRestore = snapshot()
  }

  /// Records that `changeCount` is the pasteboard state the job's selection copy produced, so the
  /// result copy can tell a later user copy from it. Call only while a restore point is held.
  func noteSelectionCopy(atChangeCount changeCount: Int) {
    guard pendingRestore != nil else { return }
    changeCountAfterSelectionCopy = changeCount
  }

  /// Drops the remembered contents without restoring them. Called when a job ends without a
  /// paste, so a later job can never put back a clipboard from minutes ago.
  func discardRestorePoint() {
    pendingRestore = nil
    changeCountAfterLastWrite = 0
    changeCountAfterSelectionCopy = nil
  }

  /// Restore for a job whose pasteboard change was made by another app (the synthetic ⌘C of Read
  /// Aloud), not by `copyToClipboard`. `changeCount` is the pasteboard state the job has just
  /// consumed; if anything writes after that, the restore is skipped like in the paste flow.
  @discardableResult
  func restorePendingSnapshot(afterForeignWriteAt changeCount: Int) -> Bool {
    changeCountAfterLastWrite = changeCount
    return restorePendingSnapshot()
  }

  /// Writes the remembered contents back and clears the restore point. No-op when nothing was
  /// captured, or when the pasteboard was empty to begin with (restoring "empty" would just
  /// throw away the dictated text for no gain).
  /// - Returns: `true` when the pasteboard was actually restored.
  @discardableResult
  func restorePendingSnapshot() -> Bool {
    guard let snapshot = pendingRestore else { return false }
    pendingRestore = nil
    changeCountAfterSelectionCopy = nil
    guard pasteboard.changeCount == changeCountAfterLastWrite else {
      DebugLogger.log("AUTO-PASTE: Skipping clipboard restore — pasteboard changed since write")
      return false
    }
    return write(snapshot)
  }

  private func write(_ snapshot: ClipboardSnapshot) -> Bool {
    guard !snapshot.isEmpty else { return false }

    pasteboard.clearContents()
    let items: [NSPasteboardItem] = snapshot.items.compactMap { representations in
      guard !representations.isEmpty else { return nil }
      let item = NSPasteboardItem()
      for (type, data) in representations {
        item.setData(data, forType: type)
      }
      return item
    }
    guard !items.isEmpty else { return false }
    pasteboard.writeObjects(items)
    lastOwnWriteChangeCount = pasteboard.changeCount
    return true
  }

  func appendToClipboard(text: String, separator: String = Constants.defaultSeparator) {
    let currentText = getClipboardText() ?? ""
    let newText = currentText.isEmpty ? text : currentText + separator + text
    copyToClipboard(text: newText)
  }

  // Format transcription text for better readability
  func formatTranscription(_ text: String, addTrailingPeriod: Bool = true) -> String {
    // Basic formatting improvements
    var formatted = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Ensure first letter is capitalized
    if !formatted.isEmpty {
      formatted = formatted.prefix(1).uppercased() + formatted.dropFirst()
    }

    // Add period if missing and text doesn't end with punctuation
    if addTrailingPeriod, let lastChar = formatted.last, !Constants.punctuation.contains(lastChar) {
      formatted += "."
    }

    return formatted
  }
}
