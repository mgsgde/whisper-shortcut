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

  func testAPIKeyValidationWithEmptyKey() {
    let expectation = XCTestExpectation(description: "API key validation with empty key")
    var validationResult: Result<Bool, Error>?

    transcriptionService.validateAPIKey("") { result in
      validationResult = result
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5.0)

    guard let result = validationResult else {
      XCTFail("No validation result received")
      return
    }

    switch result {
    case .success:
      XCTFail("Validation should fail with empty API key")
    case .failure(let error):
      let nsError = error as NSError
      XCTAssertEqual(nsError.code, 1001, "Should fail with code 1001 for empty API key")
      XCTAssertTrue(nsError.localizedDescription.contains("No API key provided"), "Should contain appropriate error message")
    }
  }

  func testAPIKeyValidationWithInvalidKey() {
    let expectation = XCTestExpectation(description: "API key validation with invalid key")
    var validationResult: Result<Bool, Error>?

    // Use an obviously invalid API key
    transcriptionService.validateAPIKey("sk-invalid-test-key") { result in
      validationResult = result
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 15.0)

    guard let result = validationResult else {
      XCTFail("No validation result received")
      return
    }

    switch result {
    case .success:
      XCTFail("Validation should fail with invalid API key")
    case .failure(let error):
      let nsError = error as NSError
      // Should get 401 error for invalid key, or network error
      if nsError.code == 401 {
        XCTAssertTrue(nsError.localizedDescription.contains("Authentication failed"), "Should contain authentication error message")
      } else {
        // Network errors are also acceptable for invalid keys
        print("Validation failed with network error (acceptable): \(error)")
      }
    }
  }
}
