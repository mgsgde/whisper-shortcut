import XCTest

@testable import WhisperShortcut

final class TranscriptionServiceTests: XCTestCase {
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

  // Removed testAPIKeyConfiguration() - just tests UserDefaults, no business logic
  // Removed testTranscriptionErrorDescriptions() - just tests string constants

  func testAPIKeyValidationWithEmptyKey() async {
    do {
      _ = try await transcriptionService.validateAPIKey("")
      XCTFail("Validation should fail with empty API key")
    } catch {
      guard let transcriptionError = error as? TranscriptionError else {
        XCTFail("Should receive TranscriptionError")
        return
      }
      XCTAssertEqual(transcriptionError, .noAPIKey, "Should fail with noAPIKey error")
    }
  }

  func testAPIKeyValidationWithInvalidKey() async {
    do {
      _ = try await transcriptionService.validateAPIKey("sk-invalid-test-key")
      XCTFail("Validation should fail with invalid API key")
    } catch {
      guard let transcriptionError = error as? TranscriptionError else {
        // Network errors are also acceptable for invalid keys
        print("Validation failed with network error (acceptable): \(error)")
        return
      }
      // Should get invalidAPIKey error for invalid key
      XCTAssertEqual(transcriptionError, .invalidAPIKey, "Should fail with invalidAPIKey error")
    }
  }
}
