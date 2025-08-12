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
      // Should get incorrectAPIKey error for invalid key (OpenAI returns "incorrect api key" for malformed keys)
      XCTAssertEqual(transcriptionError, .incorrectAPIKey, "Should fail with incorrectAPIKey error")
    }
  }

  // MARK: - Model Selection Tests
  func testModelSelection() {
    // Test default model
    XCTAssertEqual(
      transcriptionService.getCurrentModel(), .whisper1, "Default model should be whisper1")

    // Test setting different models
    transcriptionService.setModel(.gpt4oTranscribe)
    XCTAssertEqual(
      transcriptionService.getCurrentModel(), .gpt4oTranscribe,
      "Model should be set to gpt4oTranscribe")

    transcriptionService.setModel(.gpt4oMiniTranscribe)
    XCTAssertEqual(
      transcriptionService.getCurrentModel(), .gpt4oMiniTranscribe,
      "Model should be set to gpt4oMiniTranscribe")

    transcriptionService.setModel(.whisper1)
    XCTAssertEqual(
      transcriptionService.getCurrentModel(), .whisper1, "Model should be set back to whisper1")
  }

  func testAllModelsAvailable() {
    // Test that all models are available
    let allModels = TranscriptionModel.allCases
    XCTAssertEqual(allModels.count, 3, "Should have exactly 3 models available")

    XCTAssertTrue(allModels.contains(.whisper1), "Should include whisper1")
    XCTAssertTrue(allModels.contains(.gpt4oTranscribe), "Should include gpt4oTranscribe")
    XCTAssertTrue(allModels.contains(.gpt4oMiniTranscribe), "Should include gpt4oMiniTranscribe")
  }

  func testModelDisplayNames() {
    // Test that all models have proper display names
    XCTAssertEqual(
      TranscriptionModel.whisper1.displayName, "Whisper-1",
      "Whisper-1 should have correct display name")
    XCTAssertEqual(
      TranscriptionModel.gpt4oTranscribe.displayName, "GPT-4o Transcribe",
      "GPT-4o Transcribe should have correct display name")
    XCTAssertEqual(
      TranscriptionModel.gpt4oMiniTranscribe.displayName, "GPT-4o Mini Transcribe",
      "GPT-4o Mini Transcribe should have correct display name")
  }

  func testModelRawValues() {
    // Test that all models have correct raw values for API calls
    XCTAssertEqual(
      TranscriptionModel.whisper1.rawValue, "whisper-1", "Whisper-1 should have correct raw value")
    XCTAssertEqual(
      TranscriptionModel.gpt4oTranscribe.rawValue, "gpt-4o-transcribe",
      "GPT-4o Transcribe should have correct raw value")
    XCTAssertEqual(
      TranscriptionModel.gpt4oMiniTranscribe.rawValue, "gpt-4o-mini-transcribe",
      "GPT-4o Mini Transcribe should have correct raw value")
  }

  func testModelPersistence() {
    // Test that models can be saved to and loaded from UserDefaults
    let testModel = TranscriptionModel.gpt4oTranscribe

    // Save model to UserDefaults
    UserDefaults.standard.set(testModel.rawValue, forKey: "selectedTranscriptionModel")

    // Load model from UserDefaults
    if let savedModelString = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
      let savedModel = TranscriptionModel(rawValue: savedModelString)
    {
      XCTAssertEqual(savedModel, testModel, "Saved and loaded model should match")
    } else {
      XCTFail("Failed to save or load model from UserDefaults")
    }

    // Clean up
    UserDefaults.standard.removeObject(forKey: "selectedTranscriptionModel")
  }

  func testModelInitializationFromString() {
    // Test that models can be initialized from their raw string values
    XCTAssertEqual(
      TranscriptionModel(rawValue: "whisper-1"), .whisper1, "Should initialize whisper1 from string"
    )
    XCTAssertEqual(
      TranscriptionModel(rawValue: "gpt-4o-transcribe"), .gpt4oTranscribe,
      "Should initialize gpt4oTranscribe from string")
    XCTAssertEqual(
      TranscriptionModel(rawValue: "gpt-4o-mini-transcribe"), .gpt4oMiniTranscribe,
      "Should initialize gpt4oMiniTranscribe from string")

    // Test invalid string
    XCTAssertNil(
      TranscriptionModel(rawValue: "invalid-model"), "Should return nil for invalid model string")
  }
}
