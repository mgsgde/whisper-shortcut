import Testing
import CoreGraphics
@testable import WhisperShortcut_AppStore

/// Two displays in AppKit coordinates: a built-in primary and an external screen sitting above it.
/// Window-server rects use the primary's top-left as origin, y down, so the external screen is negative y.
@Suite("Indicator placement")
struct IndicatorPlacementTests {

  private let builtIn = CGRect(x: 0, y: 0, width: 1728, height: 1117)
  private let external = CGRect(x: -130, y: 1117, width: 1920, height: 1080)
  private var screens: [CGRect] { [builtIn, external] }

  /// Fullscreen window on the external display, as the window server reports it.
  private let onExternal = CGRect(x: -130, y: -1080, width: 1920, height: 1080)
  /// A normal window on the built-in display.
  private let onBuiltIn = CGRect(x: 100, y: 100, width: 800, height: 600)

  private let mouseOnBuiltIn = CGPoint(x: 400, y: 400)
  private let mouseOnExternal = CGPoint(x: 400, y: 1600)
  private let mouseOutside = CGPoint(x: 3000, y: 3000)

  private func window(
    _ bounds: CGRect, pid: Int32 = 100, layer: Int = 0, name: String = "Front"
  ) -> IndicatorPlacement.WindowInfo {
    IndicatorPlacement.WindowInfo(ownerPID: pid, ownerName: name, layer: layer, bounds: bounds)
  }

  private func place(
    pid: Int32? = 100, windows: [IndicatorPlacement.WindowInfo] = [], mouse: CGPoint = CGPoint(x: 400, y: 400),
    screenFrames: [CGRect]? = nil
  ) -> Int? {
    IndicatorPlacement.screenIndex(
      frontmostPID: pid, windows: windows, screenFrames: screenFrames ?? screens, mouse: mouse)
  }

  @Test("The frontmost window on the external screen wins, even when the mouse is on the built-in")
  func externalWindowBeatsMouseOnBuiltIn() {
    #expect(place(windows: [window(onExternal)], mouse: mouseOnBuiltIn) == 1)
  }

  @Test("The frontmost window on the built-in screen wins, even when the mouse is on the external")
  func builtInWindowBeatsMouseOnExternal() {
    #expect(place(windows: [window(onBuiltIn)], mouse: mouseOnExternal) == 0)
  }

  @Test("A window straddling both screens goes to the screen with the larger overlap")
  func straddleFollowsLargerOverlap() {
    // AppKit y 917...1917: 200 pt on the built-in, 800 pt on the external.
    let moreOnExternal = CGRect(x: 0, y: -800, width: 1000, height: 1000)
    #expect(place(windows: [window(moreOnExternal)], mouse: mouseOnBuiltIn) == 1)
    // AppKit y 317...1317: 800 pt on the built-in, 200 pt on the external.
    let moreOnBuiltIn = CGRect(x: 0, y: -200, width: 1000, height: 1000)
    #expect(place(windows: [window(moreOnBuiltIn)], mouse: mouseOnExternal) == 0)
  }

  @Test("Other apps, raised layers, and windows under 50 pt are skipped; the next normal window decides")
  func skipsNonQualifyingWindowsInFrontToBackOrder() {
    let tooNarrowOnExternal = CGRect(x: 10, y: -80, width: 49, height: 80)
    let tooShortOnExternal = CGRect(x: 10, y: -80, width: 80, height: 49)
    let exactlyMinimumOnBuiltIn = CGRect(x: 100, y: 100, width: 50, height: 50)
    let index = place(
      windows: [
        window(onExternal, pid: 200, name: "Other"),
        window(onExternal, layer: 3),
        window(tooNarrowOnExternal),
        window(tooShortOnExternal),
        window(exactlyMinimumOnBuiltIn),
        window(onExternal),
      ],
      mouse: mouseOnExternal)
    #expect(index == 0)
  }

  @Test("No qualifying window, or no frontmost app, uses the screen under the mouse; outside every screen is nil")
  func mouseDecidesWhenNoWindowQualifies() {
    let noise = [
      window(onExternal, pid: 200, name: "Other"),
      window(onBuiltIn, layer: 2),
      window(CGRect(x: 100, y: 100, width: 10, height: 10)),
    ]
    #expect(place(pid: nil, windows: [window(onExternal)], mouse: mouseOnBuiltIn) == 0)
    #expect(place(pid: nil, windows: [], mouse: mouseOnExternal) == 1)
    #expect(place(windows: noise, mouse: mouseOnExternal) == 1)
    #expect(place(pid: nil, mouse: mouseOutside) == nil)
    #expect(place(windows: noise, mouse: mouseOutside) == nil)
  }

  @Test("An empty screen list has nowhere to put the pill")
  func emptyScreenListIsNil() {
    #expect(place(windows: [window(onBuiltIn)], mouse: mouseOnBuiltIn, screenFrames: []) == nil)
  }

  @Test("A window-server rect flips into AppKit coordinates, and flipping twice returns the original")
  func appKitRectFlipsYAndIsInvolutive() {
    let original = CGRect(x: 10, y: 20, width: 100, height: 50)
    let flipped = IndicatorPlacement.appKitRect(fromWindowServer: original, primaryHeight: 1117)
    #expect(flipped == CGRect(x: 10, y: 1047, width: 100, height: 50))
    #expect(IndicatorPlacement.appKitRect(fromWindowServer: flipped, primaryHeight: 1117) == original)
  }

  @Test("The pill level stays at base, steps one above the highest covering layer, and never passes the cap")
  func levelStepsAboveCoveringLayersUpToCap() {
    #expect(IndicatorPlacement.level(coveringLayers: [], base: 25, cap: 1000) == 25)
    #expect(IndicatorPlacement.level(coveringLayers: [0, 10, 24], base: 25, cap: 1000) == 25)
    #expect(IndicatorPlacement.level(coveringLayers: [1000], base: 25, cap: 1000) == 1000)
    #expect(IndicatorPlacement.level(coveringLayers: [101, 26], base: 25, cap: 1000) == 102)
    #expect(IndicatorPlacement.level(coveringLayers: [25], base: 25, cap: 1000) == 26)
  }

  @Test("Covering windows are other apps at or above the level whose frame overlaps the pill")
  func coveringWindowsKeepOnlyOverlappingForeignWindows() {
    let pill = CGRect(x: 700, y: 1000, width: 280, height: 60)
    let cursor = Int(CGWindowLevelForKey(.cursorWindow))
    let fullscreen = window(
      CGRect(x: 0, y: 0, width: 1728, height: 1117), pid: 7, layer: 25, name: "Citrix")
    let justUnderCursor = window(
      CGRect(x: 690, y: 990, width: 40, height: 40), pid: 11, layer: cursor - 1, name: "Viewer")
    let kept = IndicatorPlacement.coveringWindows(
      [
        fullscreen,
        window(pill, pid: 42, layer: 100, name: "WhisperShortcut"),
        window(pill, pid: 7, layer: 24, name: "Below"),
        window(CGRect(x: 0, y: 0, width: 1728, height: 24), pid: 8, layer: 25, name: "Menu Bar"),
        window(pill, pid: 9, layer: cursor, name: "Cursor"),
        justUnderCursor,
      ],
      pillFrame: pill, level: 25, ownPID: 42)
    #expect(kept == [fullscreen, justUnderCursor])
  }
}
