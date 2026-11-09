import AppKit
import XCTest

@testable import WhisperShortcut_AppStore

/// The three macOS Services are the App Store build's way to receive selected text. The pasteboard
/// parsing, the Info.plist registration, and the "this selection is text, not a screenshot"
/// decision are asserted here; the handlers themselves need a live menu bar controller.
final class SelectionServicesTests: XCTestCase {
  private var pasteboards: [NSPasteboard] = []

  override func tearDown() {
    for pasteboard in pasteboards {
      pasteboard.releaseGlobally()
    }
    pasteboards.removeAll()
    super.tearDown()
  }

  private func makePasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("ws-test-\(UUID().uuidString)"))
    pasteboards.append(pasteboard)
    return pasteboard
  }

  func testTextTrimsSurroundingWhitespace() {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("  Metoprolol \n", forType: .string))
    XCTAssertEqual(SelectionServiceText.text(from: pasteboard), "Metoprolol")
  }

  func testTextRejectsWhitespaceOnly() {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("   ", forType: .string))
    XCTAssertNil(SelectionServiceText.text(from: pasteboard))
  }

  func testTextRejectsEmptyPasteboard() {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    XCTAssertNil(SelectionServiceText.text(from: pasteboard))
  }

  /// `Bundle(for:)` is the app that owns `SelectionServicesProvider`. If that comes back as the
  /// test bundle, fall back to `Bundle.main` and say which one answered.
  func testInfoPlistRegistersTheThreeServices() throws {
    let providerBundle = Bundle(for: SelectionServicesProvider.self)
    var source = "Bundle(for: SelectionServicesProvider.self)"
    var bundle = providerBundle
    var services = bundle.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]]
    if services == nil || providerBundle.bundleURL.pathExtension == "xctest" {
      source = "Bundle.main"
      bundle = Bundle.main
      services = bundle.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]]
    }
    print("SelectionServices NSServices from \(source) at \(bundle.bundlePath)")
    let entries = try XCTUnwrap(services)
    XCTAssertEqual(entries.count, 3)
    let messages = entries.compactMap { $0["NSMessage"] as? String }
    XCTAssertEqual(
      Set(messages),
      ["readAloudService", "addToGlossaryService", "dictatePromptService"])
    for message in messages {
      XCTAssertTrue(
        SelectionServicesProvider.instancesRespond(
          to: NSSelectorFromString("\(message):userData:error:")),
        message)
    }
  }

  func testServiceSelectionIsTextNotAScreenshot() async {
    let capture = DictatePromptSelectionCapture.fromService(" text ")
    XCTAssertTrue(capture.isFromService)
    let value = await capture.value()
    XCTAssertEqual(value, DictatePromptSelectionDecision.selectionText(from: " text "))
    XCTAssertFalse(DictatePromptSelectionCapture.resolved("x").isFromService)
  }

  func testScreenshotSelectionIsOffWhenTheSelectionCameFromAService() {
    XCTAssertTrue(
      SpeechService.usesScreenshotSelection(
        modelUsesScreenshotSelection: true, selectionIsFromService: false))
    XCTAssertFalse(
      SpeechService.usesScreenshotSelection(
        modelUsesScreenshotSelection: true, selectionIsFromService: true))
    XCTAssertFalse(
      SpeechService.usesScreenshotSelection(
        modelUsesScreenshotSelection: false, selectionIsFromService: false))
    XCTAssertFalse(
      SpeechService.usesScreenshotSelection(
        modelUsesScreenshotSelection: false, selectionIsFromService: true))
  }
}
