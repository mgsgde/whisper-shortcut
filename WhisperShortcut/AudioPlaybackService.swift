import Foundation
import AVFoundation

// MARK: - Audio Playback Service Implementation
class AudioPlaybackService: NSObject {
  private var audioPlayer: AVAudioPlayer?
  private var currentPlaybackCompletion: ((Bool) -> Void)?
  
  override init() {
    super.init()
    setupAudioSession()
  }
  
  // MARK: - Main Playback Method
  func playAudio(data: Data) async throws -> Bool {
    NSLog("🔊 AUDIO-PLAYBACK: Starting audio playback")
    NSLog("🔊 AUDIO-PLAYBACK: Audio data size: \(data.count) bytes")
    
    // Validate audio data
    try validateAudioData(data)
    NSLog("🔊 AUDIO-PLAYBACK: Audio data validation passed")
    
    // Stop any current playback
    stopCurrentPlayback()
    
    // Create temporary file for audio playback
    let tempURL = try createTemporaryAudioFile(data: data)
    NSLog("🔊 AUDIO-PLAYBACK: Temporary audio file created: \(tempURL.path)")
    
    defer {
      // Clean up temporary file
      try? FileManager.default.removeItem(at: tempURL)
      NSLog("🔊 AUDIO-PLAYBACK: Temporary audio file cleaned up")
    }
    
    // Create and configure audio player
    do {
      audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
      audioPlayer?.delegate = self
      audioPlayer?.prepareToPlay()
      NSLog("🔊 AUDIO-PLAYBACK: Audio player created and prepared")
    } catch {
      NSLog("⚠️ AUDIO-PLAYBACK: Failed to create audio player: \(error)")
      throw AudioPlaybackError.playbackFailed
    }
    
    // Start playback and wait for completion
    return await withCheckedContinuation { continuation in
      currentPlaybackCompletion = { success in
        continuation.resume(returning: success)
      }
      
      guard let player = audioPlayer else {
        NSLog("⚠️ AUDIO-PLAYBACK: Audio player is nil")
        continuation.resume(returning: false)
        return
      }
      
      if player.play() {
        NSLog("✅ AUDIO-PLAYBACK: Audio playback started successfully")
        NSLog("🔊 AUDIO-PLAYBACK: Duration: \(player.duration)s, Volume: \(player.volume)")
      } else {
        NSLog("⚠️ AUDIO-PLAYBACK: Failed to start audio playback")
        continuation.resume(returning: false)
      }
    }
  }
  
  // MARK: - Playback Control
  func stopPlayback() {
    NSLog("🔊 AUDIO-PLAYBACK: Stopping audio playback")
    stopCurrentPlayback()
  }
  
  private func stopCurrentPlayback() {
    if let player = audioPlayer {
      if player.isPlaying {
        player.stop()
        NSLog("🔊 AUDIO-PLAYBACK: Current playback stopped")
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
    NSLog("✅ AUDIO-PLAYBACK: Audio session setup skipped (not needed on macOS)")
  }
  
  // MARK: - Validation and Utilities
  private func validateAudioData(_ data: Data) throws {
    guard !data.isEmpty else {
      NSLog("⚠️ AUDIO-PLAYBACK: Audio data is empty")
      throw AudioPlaybackError.invalidAudioData
    }
    
    guard data.count > 100 else {
      NSLog("⚠️ AUDIO-PLAYBACK: Audio data too small: \(data.count) bytes")
      throw AudioPlaybackError.invalidAudioData
    }
    
    // Log first few bytes for debugging
    let headerBytes = Array(data.prefix(16))
    let headerHex = headerBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    NSLog("🔧 AUDIO-PLAYBACK: Audio header bytes: \(headerHex)")
    
    // More flexible format validation - check for common audio headers
    let header = Array(data.prefix(12))
    let hasValidHeader = 
      header.starts(with: [0x49, 0x44, 0x33]) ||  // ID3 (MP3)
      header.starts(with: [0xFF, 0xFB]) ||        // MPEG Layer 3 (MP3)
      header.starts(with: [0xFF, 0xFA]) ||        // MPEG Layer 3 (MP3)
      header.starts(with: [0xFF, 0xF3]) ||        // MPEG Layer 3 (MP3)
      header.starts(with: [0xFF, 0xF2]) ||        // MPEG Layer 3 (MP3)
      (header[0] == 0xFF && (header[1] & 0xE0) == 0xE0) ||  // Any MPEG audio frame
      header.starts(with: Array("RIFF".utf8)) ||   // WAV
      header.starts(with: Array("fLaC".utf8)) ||   // FLAC
      header.starts(with: Array("OggS".utf8)) ||   // OGG
      header.starts(with: Array("FORM".utf8)) ||   // AIFF
      header.starts(with: [0x66, 0x74, 0x79, 0x70]) // MP4/M4A (ftyp)
    
    if !hasValidHeader {
      NSLog("⚠️ AUDIO-PLAYBACK: Unrecognized audio format - attempting playback anyway")
      // Don't throw error, let AVAudioPlayer try to handle it
    } else {
      NSLog("✅ AUDIO-PLAYBACK: Recognized audio format")
    }
  }
  
  private func createTemporaryAudioFile(data: Data) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
    let tempURL = tempDir.appendingPathComponent("tts_audio_\(UUID().uuidString).mp3")
    
    do {
      try data.write(to: tempURL)
      return tempURL
    } catch {
      NSLog("⚠️ AUDIO-PLAYBACK: Failed to write temporary audio file: \(error)")
      throw AudioPlaybackError.playbackFailed
    }
  }
}

// MARK: - AVAudioPlayerDelegate
extension AudioPlaybackService: AVAudioPlayerDelegate {
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    NSLog("🔊 AUDIO-PLAYBACK: Audio playback finished successfully: \(flag)")
    
    if let completion = currentPlaybackCompletion {
      currentPlaybackCompletion = nil
      completion(flag)
    }
    
    audioPlayer = nil
  }
  
  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    NSLog("⚠️ AUDIO-PLAYBACK: Audio decode error: \(error?.localizedDescription ?? "Unknown error")")
    
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
