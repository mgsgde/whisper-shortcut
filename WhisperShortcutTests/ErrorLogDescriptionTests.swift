import XCTest
@testable import WhisperShortcut_AppStore

final class ErrorLogDescriptionTests: XCTestCase {
  func testAppErrorLogDescriptionContainsCaseName() {
    let text = TTSPlaybackError.noAudioProduced.logDescription
    XCTAssertFalse(text.isEmpty)
    XCTAssertTrue(text.contains("noAudioProduced"), text)
  }

  func testSystemErrorLogDescriptionContainsDomainAndCode() {
    let err = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil)
    let text = err.logDescription
    XCTAssertTrue(text.contains("\(NSCocoaErrorDomain) 4"), text)
  }
}
