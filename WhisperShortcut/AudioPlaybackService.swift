import AVFoundation
import Foundation

// MARK: - Audio Playback Service Implementation
class AudioPlaybackService: NSObject {
  // Shared instance for global access
  static let shared = AudioPlaybackService()

  private var audioPlayer: AVAudioPlayer?
  private var currentPlaybackCompletion: ((Bool) -> Void)?

  override init() {
    super.init()
    setupAudioSession()
  }

  // MARK: - Main Playback Method
  func playAudio(data: Data) async throws -> Bool {
    // Validate audio data
    try validateAudioData(data)

    // Stop any current playback
    stopCurrentPlayback()

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
        continuation.resume(returning: success)
      }

      guard let player = audioPlayer else {
        continuation.resume(returning: false)
        return
      }

      if player.play() {
        // Playback started successfully
      } else {
        continuation.resume(returning: false)
      }
    }
  }

  // MARK: - Playback Control
  func stopPlayback() {
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

    // Complete any pending playback with failure
    if let completion = currentPlaybackCompletion {
      currentPlaybackCompletion = nil
      completion(false)
    }
  }

  // MARK: - Audio Session Setup
  private func setupAudioSession() {
    // On macOS, AVAudioSession is not available
    // Audio configuration is handled automatically by the system for desktop apps

  }

  // MARK: - Validation and Utilities
  private func validateAudioData(_ data: Data) throws {
    guard !data.isEmpty else {

      throw AudioPlaybackError.invalidAudioData
    }

    guard data.count > 100 else {

      throw AudioPlaybackError.invalidAudioData
    }

    // Log first few bytes for debugging
    let headerBytes = Array(data.prefix(16))
    let headerHex = headerBytes.map { String(format: "%02X", $0) }.joined(separator: " ")

    // More flexible format validation - check for common audio headers
    let header = Array(data.prefix(12))
    let hasValidHeader =
      header.starts(with: [0x49, 0x44, 0x33])  // ID3 (MP3)
      || header.starts(with: [0xFF, 0xFB])  // MPEG Layer 3 (MP3)
      || header.starts(with: [0xFF, 0xFA])  // MPEG Layer 3 (MP3)
      || header.starts(with: [0xFF, 0xF3])  // MPEG Layer 3 (MP3)
      || header.starts(with: [0xFF, 0xF2])  // MPEG Layer 3 (MP3)
      || (header[0] == 0xFF && (header[1] & 0xE0) == 0xE0)  // Any MPEG audio frame
      || header.starts(with: Array("RIFF".utf8))  // WAV
      || header.starts(with: Array("fLaC".utf8))  // FLAC
      || header.starts(with: Array("OggS".utf8))  // OGG
      || header.starts(with: Array("FORM".utf8))  // AIFF
      || header.starts(with: [0x66, 0x74, 0x79, 0x70])  // MP4/M4A (ftyp)

    if !hasValidHeader {

      // Don't throw error, let AVAudioPlayer try to handle it
    } else {

    }
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
