import Foundation
import XCTest

@testable import WhisperShortcut

final class TranscriptionServiceIntegrationTests: XCTestCase {
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

  /// Test basic initialization and API key handling
  func testTranscriptionServiceInitialization() {
    // Test that service initializes without crashing
    XCTAssertNotNil(transcriptionService)

    // Test API key update functionality
    let testKey = "sk-test-key"
    transcriptionService.updateAPIKey(testKey)

    // Verify the key was stored in our mock
    XCTAssertEqual(mockKeychain.getAPIKey(), testKey, "API key should be stored correctly")
  }

  /// Test transcription with no API key - tests error handling
  func testTranscriptionWithNoAPIKey() {
    // Clear any existing API key
    mockKeychain.clear()

    let expectation = XCTestExpectation(description: "Transcription failed with no API key")
    var transcriptionResult: Result<String, Error>?

    // Create a dummy audio URL for testing
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.wav")

    // Create a minimal test file to avoid file not found error
    let testData = Data("test".utf8)
    try? testData.write(to: tempURL)

    transcriptionService.transcribe(audioURL: tempURL) { result in
      transcriptionResult = result
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5.0)

    // Clean up test file
    try? FileManager.default.removeItem(at: tempURL)

    guard let result = transcriptionResult else {
      XCTFail("No transcription result received")
      return
    }

    switch result {
    case .success:
      XCTFail("Transcription should have failed with no API key")
    case .failure(let error):
      if let transcriptionError = error as? TranscriptionError {
        XCTAssertEqual(
          transcriptionError, .noAPIKey,
          "Should fail with noAPIKey error when API key is missing")
      } else {
        XCTFail("Expected TranscriptionError.noAPIKey, got: \(error)")
      }
    }
  }

  /// Integration test that makes a real API call to OpenAI Whisper API
  /// Only runs if API key is available in test-config or environment
  func testRealOpenAITranscriptionIntegration() {
    // Try to get API key from config file first, then environment variable
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      print("⚠️ Skipping OpenAI integration test - No API key configured")
      print("   Create 'test-config' file with OPENAI_API_KEY=your_key")
      print("   Or set environment variable: export OPENAI_API_KEY=your_key")
      return
    }

    // Use our mock to set the API key without triggering Keychain prompts
    _ = mockKeychain.saveAPIKey(apiKey)

    // Create a simple test audio file with speech
    guard let testAudioURL = createSimpleTestAudio() else {
      XCTFail("Failed to create test audio file")
      return
    }

    let expectation = XCTestExpectation(description: "OpenAI transcription completed")
    var transcriptionResult: Result<String, Error>?

    print("🎙️ Testing real OpenAI transcription with API key: \(String(apiKey.prefix(10)))...")

    transcriptionService.transcribe(audioURL: testAudioURL) { result in
      transcriptionResult = result
      expectation.fulfill()
    }

    // Wait up to 30 seconds for the API call
    wait(for: [expectation], timeout: 30.0)

    // Clean up test file
    try? FileManager.default.removeItem(at: testAudioURL)

    // Verify the result
    guard let result = transcriptionResult else {
      XCTFail("No transcription result received")
      return
    }

    switch result {
    case .success(let transcription):
      print("✅ OpenAI transcription successful: '\(transcription)'")
      XCTAssertFalse(transcription.isEmpty, "Transcription should not be empty")
      // Basic validation - transcription should contain some text
      XCTAssertGreaterThan(transcription.count, 0, "Transcription should contain content")

    case .failure(let error):
      if let transcriptionError = error as? TranscriptionError {
        switch transcriptionError {
        case .unauthorized:
          XCTFail("API key is invalid or unauthorized: \(error.localizedDescription)")
        case .rateLimited:
          print("⚠️ Rate limited by OpenAI - this is expected behavior, not a test failure")
        // Rate limiting is not a test failure, just skip
        case .fileTooLarge:
          XCTFail("Test audio file is too large: \(error.localizedDescription)")
        default:
          XCTFail("OpenAI transcription failed: \(error.localizedDescription)")
        }
      } else {
        XCTFail("Transcription failed with unexpected error: \(error.localizedDescription)")
      }
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

  /// Creates a simple test audio file - minimal but valid WAV
  private func createSimpleTestAudio() -> URL? {
    let tempDir = FileManager.default.temporaryDirectory
    let audioURL = tempDir.appendingPathComponent("simple_test.wav")

    // Create minimal but valid WAV file (much simpler than before)
    let sampleRate: UInt32 = 16000  // Lower sample rate for smaller file
    let duration: Float = 0.5  // Half second
    let numSamples = Int(Float(sampleRate) * duration)

    var audioData = Data()

    // WAV header (44 bytes)
    audioData.append("RIFF".data(using: .ascii)!)
    audioData.append(UInt32(36 + numSamples * 2).littleEndianData)  // File size
    audioData.append("WAVE".data(using: .ascii)!)
    audioData.append("fmt ".data(using: .ascii)!)
    audioData.append(UInt32(16).littleEndianData)  // fmt chunk size
    audioData.append(UInt16(1).littleEndianData)  // PCM format
    audioData.append(UInt16(1).littleEndianData)  // Mono
    audioData.append(sampleRate.littleEndianData)  // Sample rate
    audioData.append((sampleRate * 2).littleEndianData)  // Byte rate
    audioData.append(UInt16(2).littleEndianData)  // Block align
    audioData.append(UInt16(16).littleEndianData)  // Bits per sample
    audioData.append("data".data(using: .ascii)!)
    audioData.append(UInt32(numSamples * 2).littleEndianData)  // Data size

    // Generate simple tone pattern that might be recognizable
    for i in 0..<numSamples {
      let t = Float(i) / Float(sampleRate)
      let sample = Int16(sin(2.0 * Float.pi * 440.0 * t) * 16000.0)  // 440Hz tone
      audioData.append(sample.littleEndianData)
    }

    do {
      try audioData.write(to: audioURL)
      print("🎵 Created simple test audio: \(audioURL.path) (\(audioData.count) bytes)")
      return audioURL
    } catch {
      print("❌ Failed to create test audio: \(error)")
      return nil
    }
  }

}

// MARK: - Helper Extensions

extension UInt32 {
  var littleEndianData: Data {
    return withUnsafeBytes(of: self.littleEndian) { Data($0) }
  }
}

extension UInt16 {
  var littleEndianData: Data {
    return withUnsafeBytes(of: self.littleEndian) { Data($0) }
  }
}

extension Int16 {
  var littleEndianData: Data {
    return withUnsafeBytes(of: self.littleEndian) { Data($0) }
  }
}

// MARK: - Test Extensions

extension TranscriptionError: Equatable {
  public static func == (lhs: TranscriptionError, rhs: TranscriptionError) -> Bool {
    switch (lhs, rhs) {
    case (.noAPIKey, .noAPIKey),
      (.fileTooLarge, .fileTooLarge),
      (.invalidResponse, .invalidResponse),
      (.noData, .noData),
      (.badRequest, .badRequest),
      (.unauthorized, .unauthorized),
      (.rateLimited, .rateLimited):
      return true
    case (.httpError(let code1), .httpError(let code2)):
      return code1 == code2
    case (.parseError(_), .parseError(_)):
      return true  // Simplified comparison for testing
    default:
      return false
    }
  }
}
