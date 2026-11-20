import AppKit
import CoreGraphics

/// Where the floating pill goes and how high it sits. Pure, so the decisions are unit-tested;
/// `RecordingIndicatorManager` feeds it what the window server reports.
///
/// Why not `NSScreen.main`: for an app that is not active, AppKit's "main" screen is a guess.
/// Measured 2026-11-20 on macOS 26.6 with two displays and a fullscreen app on the external
/// one: an accessory process got the external display, a `.regular` one (Dock icon on) got the
/// built-in display, and the same call flipped between runs. The pill then lit up on the screen
/// nobody was looking at — "I can't see whether it is listening" (tester, Citrix/Outlook).
/// The screen holding the frontmost app's frontmost window is where the user is typing.
enum IndicatorPlacement {
  /// One window as `CGWindowListCopyWindowInfo` reports it (top-left origin, y down).
  struct WindowInfo: Equatable {
    var ownerPID: pid_t
    var ownerName: String
    var layer: Int
    var bounds: CGRect
  }

  /// Index into `screenFrames` (AppKit coordinates, bottom-left origin) for the pill, or nil to
  /// fall back. `windows` is front-to-back, as the window list returns it. The frontmost app's
  /// first normal-layer window decides; the screen sharing the largest area with it wins.
  /// Without such a window (an app with only a menu bar up, a fullscreen game), the screen under
  /// the mouse decides, which is where the shortcut was pressed in practice.
  static func screenIndex(
    frontmostPID: pid_t?, windows: [WindowInfo], screenFrames: [CGRect], mouse: CGPoint
  ) -> Int? {
    guard let primary = screenFrames.first else { return nil }
    if let pid = frontmostPID,
      let window = windows.first(where: {
        $0.ownerPID == pid && $0.layer == 0 && $0.bounds.width >= minimumWindowSide
          && $0.bounds.height >= minimumWindowSide
      })
    {
      let frame = appKitRect(fromWindowServer: window.bounds, primaryHeight: primary.height)
      let areas = screenFrames.map { screen -> CGFloat in
        let overlap = screen.intersection(frame)
        return overlap.isNull ? 0 : overlap.width * overlap.height
      }
      if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
        return best
      }
    }
    return screenFrames.firstIndex { NSMouseInRect(mouse, $0, false) }
  }

  /// Window-server rect (origin top-left of the primary display) → AppKit rect.
  static func appKitRect(fromWindowServer rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  /// Level the pill needs so nothing of another app covers it. `base` is the normal level
  /// (`.statusBar`). Some apps cover the whole screen above it (remote-desktop viewers that
  /// capture the display in fullscreen); then the pill goes one above the highest of them,
  /// never past `cap`, so it does not climb over the lock screen or the screen saver.
  static func level(coveringLayers: [Int], base: Int, cap: Int) -> Int {
    guard let highest = coveringLayers.max(), highest >= base else { return base }
    return min(highest + 1, cap)
  }

  /// Windows of other apps that sit at or above `level` and overlap `pillFrame` (window-server
  /// coordinates). The menu bar strip and system overlays that never cover the bottom of the
  /// screen fall out by the overlap test; our own windows by `ownPID`.
  static func coveringWindows(
    _ windows: [WindowInfo], pillFrame: CGRect, level: Int, ownPID: pid_t
  ) -> [WindowInfo] {
    windows.filter {
      $0.ownerPID != ownPID && $0.layer >= level && $0.bounds.intersects(pillFrame)
        && $0.layer < Int(CGWindowLevelForKey(.cursorWindow))
    }
  }

  /// Toolbars and tiny helper windows are not where the user is typing.
  static let minimumWindowSide: CGFloat = 50

  /// Reads the on-screen window list. Main thread; cheap (a few hundred entries).
  static func onScreenWindows() -> [WindowInfo] {
    guard
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return list.compactMap { entry in
      guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
        let layer = entry[kCGWindowLayer as String] as? Int,
        let dict = entry[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: dict)
      else { return nil }
      return WindowInfo(
        ownerPID: pid, ownerName: entry[kCGWindowOwnerName as String] as? String ?? "?",
        layer: layer, bounds: bounds)
    }
  }
}
