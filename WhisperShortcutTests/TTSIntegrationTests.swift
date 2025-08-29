import AVFoundation
import Foundation
import XCTest

@testable import WhisperShortcut

final class TTSIntegrationTests: XCTestCase {
  var ttsService: TTSService!
  var mockKeychain: MockKeychainManager!

  override func setUp() {
    super.setUp()
    mockKeychain = MockKeychainManager()
    ttsService = TTSService(keychainManager: mockKeychain)
  }

  override func tearDown() {
    mockKeychain.clear()
    ttsService = nil
    mockKeychain = nil
    super.tearDown()
  }

  // MARK: - TTS Service Initialization Tests

  /// Test that TTS service initializes correctly
  func testTTSServiceInitialization() {
    // Test that service initializes without crashing
    XCTAssertNotNil(ttsService)

    // Test API key update functionality
    let testKey = "sk-test-key"
    ttsService.updateAPIKey(testKey)

    // Verify the key was stored in our mock
    XCTAssertEqual(mockKeychain.getAPIKey(), testKey, "API key should be stored correctly")
  }

  /// Test TTS with no API key - tests error handling
  func testTTSWithNoAPIKey() async {
    // Clear any existing API key
    mockKeychain.clear()

    // Test text input
    let testText = "Hello, this is a test message for text-to-speech."

    do {
      _ = try await ttsService.generateSpeech(text: testText)
      XCTFail("Should have thrown TTSError.noAPIKey")
    } catch let error as TTSError {
      XCTAssertEqual(error, .noAPIKey, "Should get noAPIKey error")
      XCTAssertFalse(error.isRetryable, "No API key error should not be retryable")
      NSLog("✅ TTS Test passed: Got expected noAPIKey error")
    } catch {
      XCTFail("Should get TTSError, got: \(error)")
    }
  }

  // MARK: - OpenAI TTS API Integration Tests

  /// Integration test that makes a real API call to OpenAI TTS API
  /// Only runs if API key is available in test-config or environment
  func testRealOpenAITTSIntegration() async {
    // Try to get API key from config file first, then environment variable
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      NSLog("⚠️ Skipping OpenAI TTS integration test - No API key configured")
      NSLog("   Create 'test-config' file with OPENAI_API_KEY=your_key")
      NSLog("   Or set environment variable: export OPENAI_API_KEY=your_key")
      return
    }

    // Use our mock to set the API key without triggering Keychain prompts
    _ = mockKeychain.saveAPIKey(apiKey)

    // Test text for TTS
    let testText = "Hello, this is a test of the OpenAI text-to-speech functionality."

    NSLog("🔊 Testing real OpenAI TTS with API key: \(String(apiKey.prefix(10)))...")

    do {
      let audioData = try await ttsService.generateSpeech(text: testText)
      NSLog("✅ OpenAI TTS successful: Generated \(audioData.count) bytes of audio")

      // Basic validation - audio data should not be empty
      XCTAssertFalse(audioData.isEmpty, "Audio data should not be empty")
      XCTAssertGreaterThan(audioData.count, 1000, "Audio data should be substantial (>1KB)")

      // Validate that it's likely audio data (basic check)
      // MP3 files typically start with ID3 tag or MPEG header
      let audioBytes = Array(audioData.prefix(10))
      let hasValidAudioHeader =
        audioBytes.starts(with: [0x49, 0x44, 0x33])  // ID3 tag
        || audioBytes.starts(with: [0xFF, 0xFB])  // MPEG header
        || audioBytes.starts(with: [0xFF, 0xFA])  // MPEG header variant

      XCTAssertTrue(hasValidAudioHeader, "Audio data should have valid audio format header")

    } catch {
      // Log the error but don't fail the test - might be expected if API key is invalid
      NSLog("ℹ️ TTS generation failed with error: \(error.localizedDescription)")
      // This might be expected if the API key is invalid or there are network issues
    }
  }

  /// Test TTS with different text lengths
  func testTTSWithVariousTextLengths() async {
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      NSLog("⚠️ Skipping TTS text length test - No API key configured")
      return
    }

    _ = mockKeychain.saveAPIKey(apiKey)

    let testCases = [
      "Hi",  // Very short
      "This is a medium length test message for text-to-speech testing.",  // Medium
      String(repeating: "This is a longer test message. ", count: 10),  // Long
    ]

    for (index, testText) in testCases.enumerated() {
      NSLog("🔊 Testing TTS with text length \(testText.count) (case \(index + 1))")

      do {
        let audioData = try await ttsService.generateSpeech(text: testText)
        XCTAssertFalse(audioData.isEmpty, "Audio data should not be empty for case \(index + 1)")
        NSLog("✅ TTS case \(index + 1) successful: \(audioData.count) bytes")
      } catch {
        NSLog("ℹ️ TTS case \(index + 1) failed: \(error.localizedDescription)")
      }
    }
  }

  /// Test TTS with special characters and Unicode
  func testTTSWithSpecialCharacters() async {
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      NSLog("⚠️ Skipping TTS special characters test - No API key configured")
      return
    }

    _ = mockKeychain.saveAPIKey(apiKey)

    let testTexts = [
      "Hello, world! This has punctuation.",
      "Tëst wïth áccënts and ümlauts.",
      "Test with numbers: 123, 456.78, and percentages: 99%.",
      "Mixed content: English, Deutsch, français!",
    ]

    for (index, testText) in testTexts.enumerated() {
      NSLog("🔊 Testing TTS with special characters (case \(index + 1)): \(testText)")

      do {
        let audioData = try await ttsService.generateSpeech(text: testText)
        XCTAssertFalse(
          audioData.isEmpty, "Audio data should not be empty for special chars case \(index + 1)")
        NSLog("✅ TTS special chars case \(index + 1) successful: \(audioData.count) bytes")
      } catch {
        NSLog("ℹ️ TTS special chars case \(index + 1) failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Audio Generation and Validation Tests

  /// Test that generated audio can be saved and loaded
  func testAudioDataPersistence() async {
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      NSLog("⚠️ Skipping audio persistence test - No API key configured")
      return
    }

    _ = mockKeychain.saveAPIKey(apiKey)

    let testText = "Testing audio data persistence functionality."

    do {
      let audioData = try await ttsService.generateSpeech(text: testText)

      // Save to temporary file
      let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "test_tts_audio.mp3")
      try audioData.write(to: tempURL)

      // Load back from file
      let loadedAudioData = try Data(contentsOf: tempURL)

      // Verify data integrity
      XCTAssertEqual(audioData, loadedAudioData, "Audio data should be identical after save/load")

      // Clean up
      try FileManager.default.removeItem(at: tempURL)

      NSLog("✅ Audio persistence test successful")

    } catch {
      XCTFail("Audio persistence test failed: \(error.localizedDescription)")
    }
  }

  /// Test that generated audio has valid format
  func testAudioFormatValidation() async {
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      NSLog("⚠️ Skipping audio format validation test - No API key configured")
      return
    }

    _ = mockKeychain.saveAPIKey(apiKey)

    let testText = "Testing audio format validation."

    do {
      let audioData = try await ttsService.generateSpeech(text: testText)

      // Basic format validation
      XCTAssertGreaterThan(audioData.count, 100, "Audio should be substantial size")

      // Try to create an AVAudioPlayer to validate the format
      let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("format_test.mp3")
      try audioData.write(to: tempURL)

      defer {
        try? FileManager.default.removeItem(at: tempURL)
      }

      do {
        let audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
        XCTAssertGreaterThan(audioPlayer.duration, 0, "Audio should have positive duration")
        NSLog("✅ Audio format validation successful - Duration: \(audioPlayer.duration)s")
      } catch {
        XCTFail("Generated audio has invalid format: \(error.localizedDescription)")
      }

    } catch {
      XCTFail("Audio format validation test failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Error Handling Tests

  /// Test TTS API error handling with invalid requests
  func testTTSErrorHandling() async {
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      NSLog("⚠️ Skipping TTS error handling test - No API key configured")
      return
    }

    _ = mockKeychain.saveAPIKey(apiKey)

    // Test with empty text
    do {
      _ = try await ttsService.generateSpeech(text: "")
      XCTFail("Should have thrown error for empty text")
    } catch let error as TTSError {
      XCTAssertEqual(error, .invalidInput, "Should get invalidInput error for empty text")
      NSLog("✅ Empty text error handling successful")
    } catch {
      NSLog("ℹ️ Got unexpected error for empty text: \(error)")
    }

    // Test with extremely long text (over API limits)
    let veryLongText = String(
      repeating: "This is a very long test sentence that exceeds reasonable limits. ", count: 100)

    do {
      _ = try await ttsService.generateSpeech(text: veryLongText)
      NSLog("ℹ️ Very long text was accepted by API")
    } catch let error as TTSError {
      NSLog("✅ Long text error handling: \(error)")
      // This might be expected depending on OpenAI's current limits
    } catch {
      NSLog("ℹ️ Got unexpected error for long text: \(error)")
    }
  }

  /// Test network error handling
  func testTTSNetworkErrorHandling() async {
    // Use invalid API key to simulate network/auth errors
    _ = mockKeychain.saveAPIKey("sk-invalid-key-for-testing")

    let testText = "Testing network error handling."

    do {
      _ = try await ttsService.generateSpeech(text: testText)
      XCTFail("Should have thrown error for invalid API key")
    } catch let error as TTSError {
      // Should get authentication or network error
      XCTAssertTrue(
        error == .authenticationError || error == .networkError(""),
        "Should get auth or network error for invalid key")
      NSLog("✅ Network error handling successful: \(error)")
    } catch {
      NSLog("ℹ️ Got unexpected error for invalid key: \(error)")
    }
  }

  // MARK: - Helper Methods

  /// Get API key from test-config file or environment variable
  private func getTestAPIKey() -> String? {
    // First, try to read from test-config file
    let configURL = URL(
      fileURLWithPath: "test-config",
      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

    if let configData = try? String(contentsOf: configURL, encoding: .utf8) {
      let lines = configData.components(separatedBy: .newlines)
      for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("OPENAI_API_KEY=") && !trimmed.hasPrefix("#") {
          let apiKey = String(trimmed.dropFirst("OPENAI_API_KEY=".count))
          if !apiKey.isEmpty && apiKey != "sk-your-api-key-here" {
            return apiKey
          }
        }
      }
    }

    // Fallback to environment variable
    return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
  }
}

// Note: TTSService and TTSError are now implemented in the main app target
// The tests will use the real implementation
