import Foundation

/// An app that can receive the synthetic ⌘V: its process id plus bundle id (either may match; a
/// restarted app gets a new pid but keeps its bundle id).
struct PasteTarget: Equatable {
  let pid: Int32
  let bundleId: String?

  func isSameApp(as other: PasteTarget) -> Bool {
    if pid == other.pid { return true }
    if let bundleId, let otherBundle = other.bundleId, bundleId == otherBundle { return true }
    return false
  }
}

/// Where auto-paste may send ⌘V. A dictation can finish minutes after it started, so the frontmost
/// app at paste time is not necessarily the one the user dictated into — and ⌘V into the wrong app
/// replaces whatever it has selected. The rule: paste only into the app that was frontmost when the
/// recording started, and never into WhisperShortcut's own windows.
///
/// Pure function of the three apps so it is testable without a window server.
enum PasteTargetPolicy {
  enum Action: Equatable {
    /// The frontmost app is the right one (or nothing was recorded and it is not us): post ⌘V.
    case pasteNow
    /// Bring the recorded app forward, wait for it to become frontmost, then post ⌘V.
    case activateRecordedThenPaste
    /// Do not post ⌘V: leave the result on the clipboard for the user's own paste.
    case clipboardOnly
  }

  /// The pill text shown when the result stayed on the clipboard.
  static let copiedHint = "Copied – press ⌘V to paste"

  static func action(frontmost: PasteTarget?, recorded: PasteTarget?, own: PasteTarget) -> Action {
    if let recorded, recorded.isSameApp(as: own) { return .clipboardOnly }
    let frontmostIsOwn = frontmost.map { $0.isSameApp(as: own) } ?? false
    guard let recorded else {
      return frontmostIsOwn || frontmost == nil ? .clipboardOnly : .pasteNow
    }
    if let frontmost, !frontmostIsOwn, frontmost.isSameApp(as: recorded) { return .pasteNow }
    return .activateRecordedThenPaste
  }
}
