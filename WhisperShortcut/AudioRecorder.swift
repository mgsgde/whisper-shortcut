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

  // MARK: - Constants
  private enum Constants {
    static let sampleRate: Double = 16000.0  // 16kHz is optimal for Whisper
    static let numberOfChannels = 1  // Mono
    static let bitDepth = 16
    static let errorDomain = "WhisperShortcut"
    static let permissionDeniedCode = 1001
    static let recordingFailedCode = 1002
    static let recordingUnsuccessfulCode = 1003
    static let emptyFileCode = 1004
  }

  override init() {
    super.init()
    setupAudioSession()
  }

  private func setupAudioSession() {
    // For macOS, AVAudioSession is not available - AVAudioRecorder handles audio setup automatically

  }

  func startRecording() {
    // Request microphone permission first
    requestMicrophonePermission { [weak self] granted in
      if granted {
        self?.beginRecording()
      } else {
        let error = NSError(
          domain: Constants.errorDomain, code: Constants.permissionDeniedCode,
          userInfo: [
            NSLocalizedDescriptionKey: "Microphone permission denied"
          ])
        self?.delegate?.audioRecorderDidFailWithError(error)
      }
    }
  }

  private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
    // Check current microphone authorization status
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:

      completion(true)

    case .notDetermined:

      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
          if granted {

            completion(true)
          } else {

            completion(false)
          }
        }
      }

    case .denied, .restricted:
      NSLog("❌ Microphone permission denied or restricted")
      completion(false)

    @unknown default:

      completion(false)
    }
  }

  private func beginRecording() {
    // Create temporary file for recording in app's container
    let documentsPath =
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let audioFilename = documentsPath.appendingPathComponent(
      "recording_\(Date().timeIntervalSince1970).wav")
    recordingURL = audioFilename

    // Audio settings optimized for speech recognition
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: Constants.sampleRate,
      AVNumberOfChannelsKey: Constants.numberOfChannels,
      AVLinearPCMBitDepthKey: Constants.bitDepth,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    do {
      // On macOS, AVAudioRecorder handles audio session setup automatically

      audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
      audioRecorder?.delegate = self

      let success = audioRecorder?.record() ?? false
      if success {
        NSLog("✅ Recording started successfully")
      } else {
        throw NSError(
          domain: Constants.errorDomain, code: Constants.recordingFailedCode,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to start recording"
          ])
      }
    } catch {

      delegate?.audioRecorderDidFailWithError(error)
    }
  }

  func stopRecording() {
    guard let recorder = audioRecorder, recorder.isRecording else {

      return
    }

    recorder.stop()

  }

  func cleanup() {
    // Simple and safe cleanup
    audioRecorder?.stop()
    audioRecorder = nil

    // Clean up temporary recording files
    if let url = recordingURL {
      try? FileManager.default.removeItem(at: url)
    }
    recordingURL = nil
  }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorder: AVAudioRecorderDelegate {
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    // Clean up the recorder instance to release microphone
    audioRecorder = nil

    if flag, let url = recordingURL {

      // Verify the file has content
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int64 ?? 0

        if fileSize > 0 {
          delegate?.audioRecorderDidFinishRecording(audioURL: url)
        } else {
          let error = NSError(
            domain: Constants.errorDomain, code: Constants.emptyFileCode,
            userInfo: [
              NSLocalizedDescriptionKey: "Recording file is empty"
            ])
          delegate?.audioRecorderDidFailWithError(error)
        }
      } catch {

        delegate?.audioRecorderDidFailWithError(error)
      }
    } else {
      let error = NSError(
        domain: Constants.errorDomain, code: Constants.recordingUnsuccessfulCode,
        userInfo: [
          NSLocalizedDescriptionKey: "Recording finished unsuccessfully"
        ])
      delegate?.audioRecorderDidFailWithError(error)
    }
  }

  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    if let error = error {

      delegate?.audioRecorderDidFailWithError(error)
    }
  }
}
