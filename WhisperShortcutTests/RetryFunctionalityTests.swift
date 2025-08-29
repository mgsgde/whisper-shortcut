import XCTest

@testable import WhisperShortcut

final class RetryFunctionalityTests: XCTestCase {
  var speechService: SpeechService!
  var mockKeychain: MockKeychainManager!

  override func setUp() {
    super.setUp()
    mockKeychain = MockKeychainManager()
    speechService = SpeechService(keychainManager: mockKeychain)
  }

  override func tearDown() {
    mockKeychain.clear()
    speechService = nil
    mockKeychain = nil
    super.tearDown()
  }

  // MARK: - Error Parsing Tests

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
    let (isError, isRetryable, errorType) = SpeechService.parseTranscriptionResult(
      timeoutError)
    XCTAssertTrue(isError, "Timeout error should be detected as error")
    XCTAssertTrue(isRetryable, "Timeout error should be retryable")
    XCTAssertEqual(errorType, .networkError("Timeout"), "Error type should be networkError")
  }

  func testNetworkErrorDetection() {
    let networkError = """
      ❌ Network Error

      Error: The operation couldn't be completed. (NSURLErrorDomain error -1001.)

      Please check your internet connection and try again.
      """

    // Test that network errors are detected correctly using the new parsing system
    let (isError, isRetryable, errorType) = SpeechService.parseTranscriptionResult(
      networkError)
    XCTAssertTrue(isError, "Network error should be detected as error")
    XCTAssertTrue(isRetryable, "Network error should be retryable")
    XCTAssertEqual(errorType, .networkError("Network"), "Error type should be networkError")
  }

  func testServerErrorDetection() {
    let serverError = """
      ❌ Internal Server Error

      An error occurred on OpenAI's servers.
      Please try again later.
      """

    // Test that server errors are detected correctly using the new parsing system
    let (isError, isRetryable, errorType) = SpeechService.parseTranscriptionResult(
      serverError)
    XCTAssertTrue(isError, "Server error should be detected as error")
    XCTAssertTrue(isRetryable, "Server error should be retryable")
    XCTAssertEqual(errorType, .serverError(500), "Error type should be serverError")
  }

  func testRateLimitErrorDetection() {
    let rateLimitError = """
      ⏳ Rate Limit Exceeded

      You have exceeded the rate limit for this API.

      Common causes for new users:
      • No billing method configured - OpenAI requires payment setup
      • Account has no credits or usage quota reached
      • Too many requests in a short time period

      To resolve:
      1. Visit platform.openai.com
      2. Go to Settings → Billing
      3. Add a payment method
      4. Purchase prepaid credits

      Note: OpenAI no longer provides free trial credits.
      You must add billing information to use the API.

      Please wait a moment and try again after setting up billing.
      """

    // Test that rate limit errors are detected correctly using the new parsing system
    let (isError, isRetryable, errorType) = SpeechService.parseTranscriptionResult(
      rateLimitError)
    XCTAssertTrue(isError, "Rate limit error should be detected as error")
    XCTAssertTrue(isRetryable, "Rate limit error should be retryable")
    XCTAssertEqual(errorType, .rateLimited, "Error type should be rateLimited")
  }

  func testServiceUnavailableErrorDetection() {
    let serviceError = """
      🔄 Service Unavailable

      OpenAI's service is temporarily unavailable.
      Please try again in a few moments.
      """

    // Test that service unavailable errors are detected correctly
    let (isError, isRetryable, errorType) = SpeechService.parseTranscriptionResult(
      serviceError)
    XCTAssertTrue(isError, "Service error should be detected as error")
    XCTAssertTrue(isRetryable, "Service error should be retryable")
    XCTAssertEqual(errorType, .serviceUnavailable, "Error type should be serviceUnavailable")
  }

  func testAuthenticationErrorDetection() {
    let authError = """
      ❌ Authentication Error

      Your API key is invalid or has expired.
      Please check your OpenAI API key in Settings.
      """

    // Test that authentication errors are detected correctly (non-retryable)
    let (isError, isRetryable, errorType) = SpeechService.parseTranscriptionResult(
      authError)
    XCTAssertTrue(isError, "Auth error should be detected as error")
    XCTAssertFalse(isRetryable, "Auth error should NOT be retryable")
    XCTAssertEqual(errorType, .invalidAPIKey, "Error type should be invalidAPIKey")
  }

  func testNonErrorTextDetection() {
    let normalText = "Hello, this is a normal transcription."

    // Test that normal text is not detected as error
    let (isError, isRetryable, errorType) = SpeechService.parseTranscriptionResult(
      normalText)
    XCTAssertFalse(isError, "Normal text should not be detected as error")
    XCTAssertFalse(isRetryable, "Normal text should not be retryable")
    XCTAssertNil(errorType, "Error type should be nil for normal text")
  }

  // MARK: - Integration Tests

  func testTranscriptionWithInvalidAPIKey() async {
    // Clear any API key (should fail with noAPIKey error)
    mockKeychain.clear()

    // Create a test audio file
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.wav")
    let testData = Data("test".utf8)
    try? testData.write(to: tempURL)

    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }

    // With new async API, this should throw a TranscriptionError
    do {
      _ = try await speechService.transcribe(audioURL: tempURL)
      XCTFail("Should have thrown TranscriptionError.noAPIKey")
    } catch let error as TranscriptionError {
      XCTAssertEqual(error, .noAPIKey, "Should get noAPIKey error")
      XCTAssertFalse(error.isRetryable, "No API key error should not be retryable")
      NSLog("✅ Test passed: Got expected noAPIKey error")
    } catch {
      XCTFail("Should get TranscriptionError, got: \(error)")
    }
  }

  func testTranscriptionWithValidAPIKeyButBadFile() async {
    // Set a test API key (will fail due to invalid audio file)
    _ = mockKeychain.saveAPIKey("sk-test-key")

    // Create an empty test file (should fail)
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("empty.wav")
    let emptyData = Data()
    try? emptyData.write(to: tempURL)

    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }

    // With new async API, this should throw a TranscriptionError
    do {
      _ = try await speechService.transcribe(audioURL: tempURL)
      XCTFail("Should have thrown TranscriptionError for empty file")
    } catch let error as TranscriptionError {
      // Should get emptyFile or fileError
      XCTAssertTrue(
        error == .emptyFile || error == .fileError("File is empty"),
        "Should get emptyFile or fileError, got: \(error)")
      NSLog("✅ Test passed: Got expected file error: \(error)")
    } catch {
      XCTFail("Should get TranscriptionError, got: \(error)")
    }
  }
}
