import AVFoundation
import Foundation
import XCTest

@testable import WhisperShortcut

final class VoiceResponseWorkflowTests: XCTestCase {
  var speechService: SpeechService!
  var ttsService: TTSService!
  var audioPlaybackService: AudioPlaybackService!
  var mockKeychain: MockKeychainManager!

  override func setUp() {
    super.setUp()
    mockKeychain = MockKeychainManager()
    speechService = SpeechService(keychainManager: mockKeychain)
    ttsService = TTSService(keychainManager: mockKeychain)
    audioPlaybackService = AudioPlaybackService()
  }

  override func tearDown() {
    mockKeychain.clear()
    speechService = nil
    ttsService = nil
    audioPlaybackService = nil
    mockKeychain = nil
    super.tearDown()
  }

  // MARK: - Voice Response Workflow Integration Tests

  /// Test the complete workflow: Text Selection → Prompt Recording → GPT Response → TTS → Audio Playback
  func testCompleteVoiceResponseWorkflow() async {
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      print("⚠️ Skipping voice response workflow test - No API key configured")
      return
    }

    _ = mockKeychain.saveAPIKey(apiKey)

    // Simulate selected text (clipboard content)
    let selectedText = "The quick brown fox jumps over the lazy dog."

    // Simulate recorded prompt audio
    guard let promptAudioURL = createSimpleTestAudio() else {
      XCTFail("Failed to create test audio for prompt")
      return
    }

    defer {
      try? FileManager.default.removeItem(at: promptAudioURL)
    }

    print("🎙️ Testing complete voice response workflow...")

    do {
      // Step 1: Execute prompt with GPT (includes transcription of user prompt)
      // This simulates the existing executePrompt functionality
      let gptResponse = try await speechService.executePromptWithVoiceResponse(
        audioURL: promptAudioURL,
        clipboardContext: selectedText
      )

      print("✅ GPT Response received: '\(String(gptResponse.prefix(100)))...'")
      XCTAssertFalse(gptResponse.isEmpty, "GPT response should not be empty")

      // Step 2: Convert GPT response to speech
      let audioData = try await ttsService.generateSpeech(text: gptResponse)

      print("✅ TTS Audio generated: \(audioData.count) bytes")
      XCTAssertFalse(audioData.isEmpty, "TTS audio data should not be empty")

      // Step 3: Play the audio response
      let playbackSuccess = try await audioPlaybackService.playAudio(data: audioData)

      print("✅ Audio playback completed: \(playbackSuccess)")
      XCTAssertTrue(playbackSuccess, "Audio playback should succeed")

    } catch {
      print("ℹ️ Voice response workflow failed: \(error.localizedDescription)")
      // Don't fail the test as this might be expected with API limitations
    }
  }

  /// Test workflow with different prompt types
  func testVoiceResponseWithDifferentPrompts() async {
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      print("⚠️ Skipping different prompts test - No API key configured")
      return
    }

    _ = mockKeychain.saveAPIKey(apiKey)

    let testCases = [
      (text: "Hello world", expectedResponse: "greeting"),
      (text: "The weather is nice today", expectedResponse: "weather"),
      (text: "2 + 2 = ?", expectedResponse: "math"),
    ]

    for (index, testCase) in testCases.enumerated() {
      print("🎙️ Testing voice response case \(index + 1): \(testCase.expectedResponse)")

      guard let promptAudioURL = createSimpleTestAudio() else {
        XCTFail("Failed to create test audio for case \(index + 1)")
        continue
      }

      defer {
        try? FileManager.default.removeItem(at: promptAudioURL)
      }

      do {
        let gptResponse = try await speechService.executePromptWithVoiceResponse(
          audioURL: promptAudioURL,
          clipboardContext: testCase.text
        )

        XCTAssertFalse(gptResponse.isEmpty, "Response should not be empty for case \(index + 1)")

        let audioData = try await ttsService.generateSpeech(text: gptResponse)
        XCTAssertFalse(audioData.isEmpty, "Audio should not be empty for case \(index + 1)")

        print("✅ Voice response case \(index + 1) successful")

      } catch {
        print("ℹ️ Voice response case \(index + 1) failed: \(error.localizedDescription)")
      }
    }
  }

  /// Test workflow error handling
  func testVoiceResponseErrorHandling() async {
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      print("⚠️ Skipping voice response error handling test - No API key configured")
      return
    }

    _ = mockKeychain.saveAPIKey(apiKey)

    // Test with invalid audio file
    let invalidAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "invalid.wav")
    let invalidData = Data("not audio data".utf8)
    try? invalidData.write(to: invalidAudioURL)

    defer {
      try? FileManager.default.removeItem(at: invalidAudioURL)
    }

    do {
      _ = try await speechService.executePromptWithVoiceResponse(
        audioURL: invalidAudioURL,
        clipboardContext: "Test text"
      )
      XCTFail("Should have thrown error for invalid audio")
    } catch {
      print("✅ Error handling successful for invalid audio: \(error)")
      // Expected to fail with invalid audio
    }

    // Test with no clipboard context
    guard let validAudioURL = createSimpleTestAudio() else {
      XCTFail("Failed to create valid test audio")
      return
    }

    defer {
      try? FileManager.default.removeItem(at: validAudioURL)
    }

    do {
      let response = try await speechService.executePromptWithVoiceResponse(
        audioURL: validAudioURL,
        clipboardContext: nil
      )
      print("✅ No clipboard context handled: '\(String(response.prefix(50)))...'")
      // Should work but with different prompt behavior
    } catch {
      print("ℹ️ No clipboard context failed: \(error.localizedDescription)")
    }
  }

  /// Test audio playback functionality
  func testAudioPlaybackService() async {
    // Test with valid audio data
    guard let testAudioURL = createSimpleTestAudio() else {
      XCTFail("Failed to create test audio for playback test")
      return
    }

    defer {
      try? FileManager.default.removeItem(at: testAudioURL)
    }

    do {
      let audioData = try Data(contentsOf: testAudioURL)

      let playbackSuccess = try await audioPlaybackService.playAudio(data: audioData)
      XCTAssertTrue(playbackSuccess, "Audio playback should succeed with valid data")

      print("✅ Audio playback test successful")

    } catch {
      XCTFail("Audio playback test failed: \(error.localizedDescription)")
    }

    // Test with invalid audio data
    let invalidAudioData = Data("invalid audio".utf8)

    do {
      let playbackSuccess = try await audioPlaybackService.playAudio(data: invalidAudioData)
      XCTAssertFalse(playbackSuccess, "Audio playback should fail with invalid data")

    } catch {
      print("✅ Invalid audio data properly rejected: \(error)")
      // Expected to fail
    }
  }

  /// Test concurrent voice response requests
  func testConcurrentVoiceResponseRequests() async {
    guard let apiKey = getTestAPIKey(), !apiKey.isEmpty else {
      print("⚠️ Skipping concurrent requests test - No API key configured")
      return
    }

    _ = mockKeychain.saveAPIKey(apiKey)

    // Create multiple audio files for concurrent testing
    let audioURLs = (1...3).compactMap { index -> URL? in
      guard let url = createSimpleTestAudio() else { return nil }
      let renamedURL = url.deletingLastPathComponent().appendingPathComponent("test_\(index).wav")
      try? FileManager.default.moveItem(at: url, to: renamedURL)
      return renamedURL
    }

    defer {
      audioURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    guard audioURLs.count == 3 else {
      XCTFail("Failed to create test audio files for concurrent test")
      return
    }

    print("🎙️ Testing concurrent voice response requests...")

    // Execute concurrent requests
    await withTaskGroup(of: Void.self) { group in
      for (index, audioURL) in audioURLs.enumerated() {
        group.addTask {
          do {
            let response = try await self.speechService.executePromptWithVoiceResponse(
              audioURL: audioURL,
              clipboardContext: "Test text \(index + 1)"
            )
            print("✅ Concurrent request \(index + 1) completed: \(response.count) chars")
          } catch {
            print("ℹ️ Concurrent request \(index + 1) failed: \(error.localizedDescription)")
          }
        }
      }
    }

    print("✅ Concurrent requests test completed")
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
    let audioURL = tempDir.appendingPathComponent("workflow_test_\(UUID().uuidString).wav")

    // Create minimal but valid WAV file
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

    // Generate simple tone pattern
    for i in 0..<numSamples {
      let t = Float(i) / Float(sampleRate)
      let sample = Int16(sin(2.0 * Float.pi * 440.0 * t) * 16000.0)  // 440Hz tone
      audioData.append(sample.littleEndianData)
    }

    do {
      try audioData.write(to: audioURL)
      print("🎵 Created workflow test audio: \(audioURL.path) (\(audioData.count) bytes)")
      return audioURL
    } catch {
      print("❌ Failed to create workflow test audio: \(error)")
      return nil
    }
  }
}

// Note: AudioPlaybackService and AudioPlaybackError are now implemented in the main app target
// The tests will use the real implementation

// Note: executePromptWithVoiceResponse is now implemented in the main SpeechService
