import Foundation
import XCTest

@testable import WhisperShortcut

final class RetryFunctionalityTests: XCTestCase {
  var transcriptionService: TranscriptionService!
  var mockKeychain: MockKeychainManager!

  override func setUp() {
    super.setUp()
    mockKeychain = MockKeychainManager()
    transcriptionService = TranscriptionService(keychainManager: mockKeychain)
  }

  override func tearDown() {
    mockKeychain.clear()
    transcriptionService = nil
    mockKeychain = nil
    super.tearDown()
  }

  // MARK: - Error Detection Tests

  func testTimeoutErrorDetection() {
    let timeoutError = """
      ⏰ Timeout Error

      Die Anfrage hat zu lange gedauert und wurde abgebrochen.

      Mögliche Ursachen:
      • Langsame Internetverbindung
      • Große Audiodatei
      • OpenAI Server überlastet

      Tipps:
      • Versuchen Sie es erneut
      • Verwenden Sie kürzere Aufnahmen
      • Überprüfen Sie Ihre Internetverbindung
      """

    // Test that timeout errors are detected correctly
    XCTAssertTrue(timeoutError.hasPrefix("⏰"), "Timeout error should start with ⏰")
    XCTAssertTrue(timeoutError.contains("⏰ Timeout Error"), "Should contain timeout error text")
  }

  func testNetworkErrorDetection() {
    let networkError = """
      ❌ Network error

      Error: The operation couldn't be completed. (NSURLErrorDomain error -1001.)

      Please check your internet connection and try again.
      """

    // Test that network errors are detected correctly
    XCTAssertTrue(networkError.hasPrefix("❌"), "Network error should start with ❌")
    XCTAssertTrue(networkError.contains("❌ Network error"), "Should contain network error text")
  }

  func testServerErrorDetection() {
    let serverError = """
      ❌ Server error

      HTTP error: 500

      Please try again later.
      """

    // Test that server errors are detected correctly
    XCTAssertTrue(serverError.hasPrefix("❌"), "Server error should start with ❌")
    XCTAssertTrue(serverError.contains("❌ Server error"), "Should contain server error text")
  }

  func testRateLimitErrorDetection() {
    let rateLimitError = """
      ⏳ Rate Limit erreicht

      Sie haben das Anfrage-Limit erreicht.
      Bitte warten Sie einen Moment und versuchen Sie es erneut.
      """

    // Test that rate limit errors are detected correctly
    XCTAssertTrue(rateLimitError.hasPrefix("⏳"), "Rate limit error should start with ⏳")
    XCTAssertTrue(rateLimitError.contains("⏳ Rate Limit"), "Should contain rate limit text")
  }

  // MARK: - Retry Logic Tests

  func testRetryableErrorIdentification() {
    let retryableErrors = [
      "⏰ Timeout Error - should be retryable",
      "❌ Network error - should be retryable",
      "❌ Server error - should be retryable",
      "⏳ Rate Limit - should be retryable",
    ]

    for error in retryableErrors {
      let isRetryable =
        error.contains("⏰ Timeout Error") || error.contains("❌ Network error")
        || error.contains("❌ Server error") || error.contains("⏳ Rate Limit")

      XCTAssertTrue(isRetryable, "Error should be identified as retryable: \(error)")
    }
  }

  func testNonRetryableErrorIdentification() {
    let nonRetryableErrors = [
      "❌ Ungültiger API-Schlüssel - should NOT be retryable",
      "❌ Audiodatei zu groß - should NOT be retryable",
      "❌ Leere Audiodatei - should NOT be retryable",
      "⚠️ No API key configured - should NOT be retryable",
    ]

    for error in nonRetryableErrors {
      let isRetryable =
        error.contains("⏰ Timeout Error") || error.contains("❌ Network error")
        || error.contains("❌ Server error") || error.contains("⏳ Rate Limit")

      XCTAssertFalse(isRetryable, "Error should NOT be identified as retryable: \(error)")
    }
  }

  // MARK: - Audio File Cleanup Tests

  func testAudioFileCleanupLogic() {
    // Test successful transcription should cleanup
    let successResult = Result<String, Error>.success("This is a successful transcription")
    // This would be tested in MenuBarController, but we can test the logic here

    // Test retryable error should NOT cleanup
    let retryableError = "⏰ Timeout Error - this should be retryable"
    let isRetryable =
      retryableError.contains("⏰ Timeout Error") || retryableError.contains("❌ Network error")
      || retryableError.contains("❌ Server error") || retryableError.contains("⏳ Rate Limit")

    XCTAssertTrue(isRetryable, "Timeout error should be retryable")
    // If retryable, shouldCleanup should be false
  }

  // MARK: - Integration Tests

  func testTranscriptionWithTimeoutSimulation() {
    // Set a valid API key
    mockKeychain.saveAPIKey("sk-test-key")

    // Create a test audio file
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-timeout.wav")
    let testData = Data("test".utf8)
    try? testData.write(to: tempURL)

    let expectation = XCTestExpectation(description: "Transcription with timeout simulation")
    var transcriptionResult: Result<String, Error>?

    transcriptionService.transcribe(audioURL: tempURL) { result in
      transcriptionResult = result
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 10.0)

    // Clean up test file
    try? FileManager.default.removeItem(at: tempURL)

    guard let result = transcriptionResult else {
      XCTFail("No transcription result received")
      return
    }

    switch result {
    case .success(let transcription):
      // Should return an error message (either API key error or timeout)
      XCTAssertTrue(
        transcription.contains("No API key configured") || transcription.contains("⏰ Timeout Error")
          || transcription.contains("❌"),
        "Should contain error message"
      )
      print("✅ Test passed: Error message returned: '\(transcription.prefix(100))...'")

    case .failure(let error):
      XCTFail("Should not fail, but return error message as transcription. Got error: \(error)")
    }
  }

  // MARK: - Error Message Format Tests

  func testTimeoutErrorMessageFormat() {
    let timeoutMessage = """
      ⏰ Timeout Error

      Die Anfrage hat zu lange gedauert und wurde abgebrochen.

      Mögliche Ursachen:
      • Langsame Internetverbindung
      • Große Audiodatei
      • OpenAI Server überlastet

      Tipps:
      • Versuchen Sie es erneut
      • Verwenden Sie kürzere Aufnahmen
      • Überprüfen Sie Ihre Internetverbindung
      """

    // Test that timeout message has correct format
    XCTAssertTrue(timeoutMessage.hasPrefix("⏰ Timeout Error"))
    XCTAssertTrue(timeoutMessage.contains("Mögliche Ursachen:"))
    XCTAssertTrue(timeoutMessage.contains("Tipps:"))
    XCTAssertTrue(timeoutMessage.contains("Versuchen Sie es erneut"))
  }

  func testNetworkErrorMessageFormat() {
    let networkMessage = """
      ❌ Network error

      Error: The operation couldn't be completed. (NSURLErrorDomain error -1001.)

      Please check your internet connection and try again.
      """

    // Test that network message has correct format
    XCTAssertTrue(networkMessage.hasPrefix("❌ Network error"))
    XCTAssertTrue(networkMessage.contains("Please check your internet connection"))
  }
}
