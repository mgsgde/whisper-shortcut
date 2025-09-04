import AVFoundation
import Foundation

// MARK: - Audio Playback Service Implementation
class AudioPlaybackService: NSObject {
  // Shared instance for global access
  static let shared = AudioPlaybackService()

  private var audioPlayer: AVAudioPlayer?
  private var currentPlaybackCompletion: ((Bool) -> Void)?
  private var wasStoppedByUser: Bool = false

  override init() {
    super.init()
  }

  // MARK: - Main Playback Method
  func playAudio(data: Data) async throws -> PlaybackResult {

    // Reset user stop flag
    wasStoppedByUser = false

    // Validate audio data
    try validateAudioData(data)

    // Stop any current playback
    stopCurrentPlayback()

    // Notify that playback is starting
    NotificationCenter.default.post(name: NSNotification.Name("VoicePlaybackStarted"), object: nil)

    // Create temporary file for audio playback
    let tempURL = try createTemporaryAudioFile(data: data)

    defer {
      // Clean up temporary file
      try? FileManager.default.removeItem(at: tempURL)

    }

    // Create and configure audio player
    do {
      audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
      audioPlayer?.delegate = self
      audioPlayer?.prepareToPlay()

    } catch {

      throw AudioPlaybackError.playbackFailed
    }

    // Start playback and wait for completion
    return await withCheckedContinuation { continuation in
      currentPlaybackCompletion = { success in
        let result: PlaybackResult
        if success {
          result = .completedSuccessfully
        } else if self.wasStoppedByUser {
          result = .stoppedByUser
        } else {
          result = .failed
        }
        continuation.resume(returning: result)
      }

      guard let player = audioPlayer else {

        continuation.resume(returning: .failed)
        return
      }

      if player.play() {

      } else {

        continuation.resume(returning: .failed)
      }
    }
  }

  // MARK: - Playback Control
  func stopPlayback() {
    wasStoppedByUser = true
    stopCurrentPlayback()
  }

  private func stopCurrentPlayback() {
    if let player = audioPlayer {
      if player.isPlaying {
        player.stop()
        // Notify that playback was stopped
        NotificationCenter.default.post(
          name: NSNotification.Name("VoicePlaybackStopped"), object: nil)
      }
      audioPlayer = nil
    }

    // Complete any pending playback
    if let completion = currentPlaybackCompletion {
      currentPlaybackCompletion = nil
      completion(false)
    }
  }

  // MARK: - Validation and Utilities
  private func validateAudioData(_ data: Data) throws {
    guard !data.isEmpty else {
      throw AudioPlaybackError.invalidAudioData
    }

    // Check for common audio file headers
    let headerBytes = Array(data.prefix(16))

    // MP3 header check (ID3 or MPEG sync)
    if headerBytes.count >= 3 {
      // ID3v2 header
      if headerBytes[0] == 0x49 && headerBytes[1] == 0x44 && headerBytes[2] == 0x33 {
        return
      }

      // MPEG sync bytes
      if headerBytes[0] == 0xFF && (headerBytes[1] & 0xE0) == 0xE0 {
        return
      }
    }

    // WAV header check
    if headerBytes.count >= 12 {
      if headerBytes[0] == 0x52 && headerBytes[1] == 0x49 && headerBytes[2] == 0x46
        && headerBytes[3] == 0x46 && headerBytes[8] == 0x57 && headerBytes[9] == 0x41
        && headerBytes[10] == 0x56 && headerBytes[11] == 0x45
      {
        return
      }
    }

    // If we get here, we couldn't identify the audio format
    // But we'll still try to play it - AVAudioPlayer might handle it
  }

  private func createTemporaryAudioFile(data: Data) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
    let tempURL = tempDir.appendingPathComponent("tts_audio_\(UUID().uuidString).mp3")

    do {
      try data.write(to: tempURL)
      return tempURL
    } catch {

      throw AudioPlaybackError.playbackFailed
    }
  }
}

// MARK: - AVAudioPlayerDelegate
extension AudioPlaybackService: AVAudioPlayerDelegate {
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    NSLog("🔇 AUDIO-PLAYBACK: Playback finished successfully: \(flag)")

    // Notify that playback finished naturally
    NotificationCenter.default.post(name: NSNotification.Name("VoicePlaybackStopped"), object: nil)

    if let completion = currentPlaybackCompletion {
      currentPlaybackCompletion = nil
      completion(flag)
    }

    audioPlayer = nil
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {

    if let completion = currentPlaybackCompletion {
      currentPlaybackCompletion = nil
      completion(false)
    }

    audioPlayer = nil
  }
}

// MARK: - Audio Playback Result Types
enum PlaybackResult {
  case completedSuccessfully
  case stoppedByUser
  case failed
}

// MARK: - Audio Playback Error Types
enum AudioPlaybackError: Error {
  case invalidAudioData
  case playbackFailed

  var localizedDescription: String {
    switch self {
    case .invalidAudioData:
      return "Invalid audio data provided"
    case .playbackFailed:
      return "Audio playback failed"
    }
  }
}
