import XCTest

@testable import WhisperShortcut

final class ClipboardManagerTests: XCTestCase {
  var clipboardManager: ClipboardManager!

  override func setUp() {
    super.setUp()
    clipboardManager = ClipboardManager()
  }

  override func tearDown() {
    clipboardManager = nil
    super.tearDown()
  }

  func testFormatTranscription() {
    // Test capitalization
    let input1 = "hello world"
    let output1 = clipboardManager.formatTranscription(input1)
    XCTAssertEqual(output1, "Hello world.")

    // Test trimming whitespace
    let input2 = "  hello world  "
    let output2 = clipboardManager.formatTranscription(input2)
    XCTAssertEqual(output2, "Hello world.")

    // Test existing punctuation preservation
    let input3 = "Hello world!"
    let output3 = clipboardManager.formatTranscription(input3)
    XCTAssertEqual(output3, "Hello world!")

    // Test empty string
    let input4 = ""
    let output4 = clipboardManager.formatTranscription(input4)
    XCTAssertEqual(output4, "")
  }

  func testCopyToClipboard() {
    let testText = "Test transcription"
    clipboardManager.copyToClipboard(text: testText)

    let clipboardText = clipboardManager.getClipboardText()
    // copyToClipboard formats the text, so we expect the formatted version
    XCTAssertEqual(clipboardText, "Test transcription.")
  }
}
