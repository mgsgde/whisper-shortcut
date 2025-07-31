import AVFoundation
import Foundation

protocol AudioRecorderDelegate: AnyObject {
  func audioRecorderDidFinishRecording(audioURL: URL)
  func audioRecorderDidFailWithError(_ error: Error)
}

class AudioRecorder: NSObject {
  weak var delegate: AudioRecorderDelegate?

  private var audioRecorder: AVAudioRecorder?

  private var recordingURL: URL?

  override init() {
    super.init()
    setupAudioSession()
  }

  private func setupAudioSession() {
    // No setup needed for macOS - AVAudioRecorder handles this automatically
    print("Audio recorder initialized for macOS")
  }

  func startRecording() {
    // Request microphone permission first
    requestMicrophonePermission { [weak self] granted in
      if granted {
        self?.beginRecording()
      } else {
        let error = NSError(
          domain: "WhisperShortcut", code: 1001,
          userInfo: [
            NSLocalizedDescriptionKey: "Microphone permission denied"
          ])
        self?.delegate?.audioRecorderDidFailWithError(error)
      }
    }
  }

  private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
    // macOS handles microphone permissions automatically when recording starts
    completion(true)
  }

  private func beginRecording() {
    // Create temporary file for recording
    let documentsPath = FileManager.default.temporaryDirectory
    let audioFilename = documentsPath.appendingPathComponent(
      "recording_\(Date().timeIntervalSince1970).wav")
    recordingURL = audioFilename

    // Audio settings optimized for speech recognition
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16000.0,  // 16kHz is optimal for Whisper
      AVNumberOfChannelsKey: 1,  // Mono
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    do {
      audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
      audioRecorder?.delegate = self
      audioRecorder?.isMeteringEnabled = true

      let success = audioRecorder?.record() ?? false
      if success {
        print("Recording started successfully")
      } else {
        throw NSError(
          domain: "WhisperShortcut", code: 1002,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to start recording"
          ])
      }
    } catch {
      print("Failed to start recording: \(error)")
      delegate?.audioRecorderDidFailWithError(error)
    }
  }

  func stopRecording() {
    guard let recorder = audioRecorder, recorder.isRecording else {
      print("No active recording to stop")
      return
    }

    recorder.stop()
    print("Recording stopped")
  }

  func cleanup() {
    audioRecorder?.stop()
    audioRecorder = nil

    // Clean up temporary recording files
    if let url = recordingURL {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorder: AVAudioRecorderDelegate {
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    if flag, let url = recordingURL {
      print("Recording finished successfully: \(url.path)")
      delegate?.audioRecorderDidFinishRecording(audioURL: url)
    } else {
      let error = NSError(
        domain: "WhisperShortcut", code: 1003,
        userInfo: [
          NSLocalizedDescriptionKey: "Recording finished unsuccessfully"
        ])
      delegate?.audioRecorderDidFailWithError(error)
    }
  }

  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    if let error = error {
      print("Audio recorder encode error: \(error)")
      delegate?.audioRecorderDidFailWithError(error)
    }
  }
}
