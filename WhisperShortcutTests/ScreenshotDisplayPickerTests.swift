import Testing
import CoreGraphics
@testable import WhisperShortcut_AppStore

@Suite("Screenshot display picker")
struct ScreenshotDisplayPickerTests {
  private let left = ScreenshotDisplayPicker.Candidate(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
  private let right = ScreenshotDisplayPicker.Candidate(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
  private let above = ScreenshotDisplayPicker.Candidate(id: 3, frame: CGRect(x: 0, y: -800, width: 1000, height: 800))

  @Test("The display holding the frontmost window wins over the mouse")
  func windowWins() {
    let id = ScreenshotDisplayPicker.pick(
      candidates: [left, right], windowCenter: CGPoint(x: 1500, y: 400), mouse: CGPoint(x: 10, y: 10), mainDisplayID: 1)
    #expect(id == 2)
  }

  @Test("Without a window the mouse decides, including displays at negative coordinates")
  func mouseFallback() {
    let id = ScreenshotDisplayPicker.pick(
      candidates: [left, right, above], windowCenter: nil, mouse: CGPoint(x: 500, y: -100), mainDisplayID: 1)
    #expect(id == 3)
  }

  @Test("A window center off every display falls through to the mouse")
  func offScreenWindow() {
    let id = ScreenshotDisplayPicker.pick(
      candidates: [left, right], windowCenter: CGPoint(x: 9000, y: 9000), mouse: CGPoint(x: 1200, y: 100), mainDisplayID: 1)
    #expect(id == 2)
  }

  @Test("No hit falls back to the main display, then to the first candidate")
  func mainThenFirst() {
    #expect(ScreenshotDisplayPicker.pick(candidates: [left, right], windowCenter: nil, mouse: nil, mainDisplayID: 2) == 2)
    #expect(ScreenshotDisplayPicker.pick(candidates: [left, right], windowCenter: nil, mouse: nil, mainDisplayID: 99) == 1)
    #expect(ScreenshotDisplayPicker.pick(candidates: [], windowCenter: nil, mouse: nil, mainDisplayID: 1) == nil)
  }
}
