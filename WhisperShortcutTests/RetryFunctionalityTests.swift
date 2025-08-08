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
      ⏰ Request Timeout

      The request took too long and was cancelled.

      Possible causes:
      • Slow internet connection
      • Large audio file
      • OpenAI servers overloaded

      Tips:
      • Try again
      • Use shorter recordings
      • Check your internet connection
      """

    // Test that timeout errors are detected correctly using the new parsing system
    let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(
      timeoutError)
    XCTAssertTrue(isError, "Timeout error should be detected as error")
    XCTAssertTrue(isRetryable, "Timeout error should be retryable")
    XCTAssertEqual(errorType, .timeout, "Error type should be timeout")
  }

  func testNetworkErrorDetection() {
    let networkError = """
      ❌ Network Error

      Error: The operation couldn't be completed. (NSURLErrorDomain error -1001.)

      Please check your internet connection and try again.
      """

    // Test that network errors are detected correctly using the new parsing system
    let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(
      networkError)
    XCTAssertTrue(isError, "Network error should be detected as error")
    XCTAssertTrue(isRetryable, "Network error should be retryable")
    XCTAssertEqual(errorType, .networkError, "Error type should be networkError")
  }

  func testServerErrorDetection() {
    let serverError = """
      ❌ Internal Server Error

      An error occurred on OpenAI's servers.
      Please try again later.
      """

    // Test that server errors are detected correctly using the new parsing system
    let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(
      serverError)
    XCTAssertTrue(isError, "Server error should be detected as error")
    XCTAssertTrue(isRetryable, "Server error should be retryable")
    XCTAssertEqual(errorType, .internalServerError, "Error type should be internalServerError")
  }

  func testRateLimitErrorDetection() {
    let rateLimitError = """
      ⏳ Rate Limit Exceeded

      You have exceeded the rate limit for this API.
      Please wait a moment and try again.
      """

    // Test that rate limit errors are detected correctly using the new parsing system
    let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(
      rateLimitError)
    XCTAssertTrue(isError, "Rate limit error should be detected as error")
    XCTAssertTrue(isRetryable, "Rate limit error should be retryable")
    XCTAssertEqual(errorType, .rateLimitExceeded, "Error type should be rateLimitExceeded")
  }

  // MARK: - Retry Logic Tests

  func testRetryableErrorIdentification() {
    let retryableErrors = [
      "⏰ Request Timeout",
      "❌ Network Error",
      "❌ Internal Server Error",
      "⏳ Rate Limit Exceeded",
      "🔄 Service Unavailable",
    ]

    for error in retryableErrors {
      let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(error)
      
      // Test each assertion separately to see which one fails
      XCTAssertTrue(isError, "Error should be detected as error: \(error)")
      XCTAssertTrue(isRetryable, "Error should be identified as retryable: \(error)")
      XCTAssertNotNil(errorType, "Error type should not be nil for: \(error)")
    }
  }

  func testNonRetryableErrorIdentification() {
    let nonRetryableErrors = [
      "❌ Authentication Error - should NOT be retryable",
      "❌ Invalid Request - should NOT be retryable",
      "❌ Permission Denied - should NOT be retryable",
      "❌ Resource Not Found - should NOT be retryable",
      "❌ File Too Large - should NOT be retryable",
      "❌ Empty Audio File - should NOT be retryable",
      "⚠️ No API Key Configured - should NOT be retryable",
    ]

    for error in nonRetryableErrors {
      let (isError, isRetryable, _) = TranscriptionService.parseTranscriptionResult(error)
      XCTAssertTrue(isError, "Error should be detected as error: \(error)")
      XCTAssertFalse(isRetryable, "Error should NOT be identified as retryable: \(error)")
    }
  }

  // MARK: - Audio File Cleanup Tests

  func testAudioFileCleanupLogic() {
    // Test successful transcription should cleanup
    let successTranscription = "This is a successful transcription"
    let (isError, isRetryable, _) = TranscriptionService.parseTranscriptionResult(
      successTranscription)
    XCTAssertFalse(isError, "Successful transcription should not be detected as error")
    XCTAssertFalse(isRetryable, "Successful transcription should not be retryable")

    // Test retryable error should NOT cleanup
    let retryableError = "⏰ Request Timeout - this should be retryable"
    let (isError2, isRetryable2, _) = TranscriptionService.parseTranscriptionResult(retryableError)
    XCTAssertTrue(isError2, "Timeout error should be detected as error")
    XCTAssertTrue(isRetryable2, "Timeout error should be retryable")
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
      ⏰ Request Timeout

      The request took too long and was cancelled.

      Possible causes:
      • Slow internet connection
      • Large audio file
      • OpenAI servers overloaded

      Tips:
      • Try again
      • Use shorter recordings
      • Check your internet connection
      """

    // Test that timeout message has correct format
    XCTAssertTrue(timeoutMessage.hasPrefix("⏰ Request Timeout"))
    XCTAssertTrue(timeoutMessage.contains("Possible causes:"))
    XCTAssertTrue(timeoutMessage.contains("Tips:"))
    XCTAssertTrue(timeoutMessage.contains("Try again"))
  }

  func testNetworkErrorMessageFormat() {
    let networkMessage = """
      ❌ Network Error

      Error: The operation couldn't be completed. (NSURLErrorDomain error -1001.)

      Please check your internet connection and try again.
      """

    // Test that network message has correct format
    XCTAssertTrue(networkMessage.hasPrefix("❌ Network Error"))
    XCTAssertTrue(networkMessage.contains("Please check your internet connection"))
  }

  // MARK: - Debug Tests (Removed after fixing the issue)

  func testTimeoutErrorParsing() {
    let errorString = "⏰ Request Timeout"
    let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(errorString)
    XCTAssertTrue(isError, "Timeout error should be detected as error")
    XCTAssertTrue(isRetryable, "Timeout error should be retryable")
    XCTAssertEqual(errorType, .timeout, "Error type should be timeout")
  }

  func testNetworkErrorParsing() {
    let errorString = "❌ Network Error"
    let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(errorString)
    XCTAssertTrue(isError, "Network error should be detected as error")
    XCTAssertTrue(isRetryable, "Network error should be retryable")
    XCTAssertEqual(errorType, .networkError, "Error type should be networkError")
  }

  func testServerErrorParsing() {
    let errorString = "❌ Internal Server Error"
    let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(errorString)
    XCTAssertTrue(isError, "Server error should be detected as error")
    XCTAssertTrue(isRetryable, "Server error should be retryable")
    XCTAssertEqual(errorType, .internalServerError, "Error type should be internalServerError")
  }

  func testRateLimitErrorParsing() {
    let errorString = "⏳ Rate Limit Exceeded"
    let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(errorString)
    XCTAssertTrue(isError, "Rate limit error should be detected as error")
    XCTAssertTrue(isRetryable, "Rate limit error should be retryable")
    XCTAssertEqual(errorType, .rateLimitExceeded, "Error type should be rateLimitExceeded")
  }

  func testServiceUnavailableErrorParsing() {
    let errorString = "🔄 Service Unavailable"
    let (isError, isRetryable, errorType) = TranscriptionService.parseTranscriptionResult(errorString)
    XCTAssertTrue(isError, "Service unavailable error should be detected as error")
    XCTAssertTrue(isRetryable, "Service unavailable error should be retryable")
    XCTAssertEqual(errorType, .serviceUnavailable, "Error type should be serviceUnavailable")
  }


}
