import AppKit
import CoreGraphics

/// Chooses which display a screenshot-based Dictate Prompt should capture: the one the user is
/// working on, not whichever ScreenCaptureKit happens to list first.
enum ScreenshotDisplayPicker {
  struct Candidate: Equatable {
    let id: CGDirectDisplayID
    /// Frame in global display coordinates (origin top-left of the main display, y down) — the
    /// space `CGDisplayBounds`, `SCDisplay.frame`, window bounds and `CGEvent.location` share.
    let frame: CGRect
  }

  /// Pure selection. The display containing `windowCenter` wins, then the one containing `mouse`,
  /// then `mainDisplayID` if it is among the candidates, then the first candidate. Nil only when
  /// there are no candidates.
  static func pick(
    candidates: [Candidate], windowCenter: CGPoint?, mouse: CGPoint?, mainDisplayID: CGDirectDisplayID
  ) -> CGDirectDisplayID? {
    for point in [windowCenter, mouse].compactMap({ $0 }) {
      if let hit = candidates.first(where: { $0.frame.contains(point) }) { return hit.id }
    }
    if candidates.contains(where: { $0.id == mainDisplayID }) { return mainDisplayID }
    return candidates.first?.id
  }

  /// Center of the topmost normal window of the frontmost application, in global display
  /// coordinates. `CGWindowListCopyWindowInfo` lists on-screen windows front to back and reports
  /// bounds without needing Screen Recording.
  static func frontmostWindowCenter() -> CGPoint? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return nil }
    for window in windows {
      guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
        (window[kCGWindowLayer as String] as? Int) == 0,
        let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDict),
        bounds.width > 1, bounds.height > 1
      else { continue }
      return CGPoint(x: bounds.midX, y: bounds.midY)
    }
    return nil
  }

  /// The display id to capture right now, from the live display configuration.
  static func currentTargetDisplayID() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let candidates = ids.prefix(Int(count)).map { Candidate(id: $0, frame: CGDisplayBounds($0)) }
    return pick(
      candidates: candidates, windowCenter: frontmostWindowCenter(),
      mouse: CGEvent(source: nil)?.location, mainDisplayID: CGMainDisplayID())
  }
}
