import AVFoundation
import Foundation

/// Delegate protocol for receiving live meeting recording events
protocol LiveMeetingRecorderDelegate: AnyObject {
  /// Called when a chunk has finished recording and is ready for transcription
  /// - Parameters:
  ///   - audioURL: URL to the recorded audio file
  ///   - chunkIndex: Index of the chunk (0-based)
  ///   - startTime: Time offset from meeting start in seconds
  func liveMeetingRecorder(didFinishChunk audioURL: URL, chunkIndex: Int, startTime: TimeInterval)
  
  /// Called when recording fails
  func liveMeetingRecorder(didFailWithError error: Error)
}

/// Double-buffer audio recorder for seamless live meeting transcription.
/// Uses two AVAudioRecorder instances that alternate to ensure no audio is lost
/// during transcription processing.
class LiveMeetingRecorder: NSObject {
  
  // MARK: - Constants
  private enum Constants {
    static let sampleRate: Double = 24000.0  // 24kHz to match Gemini requirements
    static let numberOfChannels = 1  // Mono
    static let bitDepth = 16
    static let errorDomain = "LiveMeetingRecorder"
    static let permissionDeniedCode = 2001
    static let recordingFailedCode = 2002
  }
  
  // MARK: - Properties
  weak var delegate: LiveMeetingRecorderDelegate?
  
  /// Duration of each recording chunk in seconds
  private var chunkDuration: TimeInterval
  
  /// Double-buffer recorders
  private var recorderA: AVAudioRecorder?
  private var recorderB: AVAudioRecorder?
  
  /// Currently active recorder (points to A or B)
  private var activeRecorder: AVAudioRecorder?
  
  /// URL for currently recording audio
  private var activeRecordingURL: URL?
  
  /// Timer for chunk rotation
  private var chunkTimer: Timer?
  
  /// Current chunk index
  private var chunkIndex: Int = 0
  
  /// Session start time for calculating timestamps
  private var sessionStartTime: Date?
  
  /// Current chunk start time (relative to session start)
  private var currentChunkStartTime: TimeInterval = 0
  
  /// Flag indicating if session is active
  private(set) var isSessionActive: Bool = false
  
  /// Flag indicating which recorder is active (true = A, false = B)
  private var isRecorderAActive: Bool = true
  
  // MARK: - Initialization
  
  init(chunkDuration: TimeInterval = AppConstants.liveMeetingChunkIntervalDefault) {
    self.chunkDuration = chunkDuration
    super.init()
  }
  
  // MARK: - Public Methods
  
  /// Starts a new live meeting recording session
  func startSession() {
    DebugLogger.log("LIVE-MEETING: Starting session with \(chunkDuration)s chunks")
    
    requestMicrophonePermission { [weak self] granted in
      guard let self = self else { return }
      
      if granted {
        self.beginSession()
      } else {
        let error = NSError(
          domain: Constants.errorDomain,
          code: Constants.permissionDeniedCode,
          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
        )
        self.delegate?.liveMeetingRecorder(didFailWithError: error)
      }
    }
  }
  
  /// Stops the current session and delivers the final chunk
  func stopSession() {
    DebugLogger.log("LIVE-MEETING: Stopping session")
    
    isSessionActive = false
    chunkTimer?.invalidate()
    chunkTimer = nil
    
    // Stop the active recorder and deliver the final chunk
    if let activeRecorder = activeRecorder, activeRecorder.isRecording {
      activeRecorder.stop()
      // The delegate callback will be triggered by AVAudioRecorderDelegate
    }
  }
  
  // MARK: - Private Methods
  
  private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
          completion(granted)
        }
      }
    case .denied, .restricted:
      DebugLogger.logWarning("LIVE-MEETING: Microphone permission denied or restricted")
      completion(false)
    @unknown default:
      completion(false)
    }
  }
  
  private func beginSession() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      
      self.sessionStartTime = Date()
      self.chunkIndex = 0
      self.currentChunkStartTime = 0
      self.isSessionActive = true
      self.isRecorderAActive = true
      
      // Start first recording with recorder A
      do {
        try self.startRecording(isRecorderA: true)
        self.scheduleChunkTimer()
      } catch {
        DebugLogger.logError("LIVE-MEETING: Failed to start session: \(error)")
        self.delegate?.liveMeetingRecorder(didFailWithError: error)
      }
    }
  }
  
  private func startRecording(isRecorderA: Bool) throws {
    let url = createRecordingURL(isRecorderA: isRecorderA)
    let settings = createRecordingSettings()
    
    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.delegate = self
    
    if isRecorderA {
      recorderA = recorder
    } else {
      recorderB = recorder
    }
    
    activeRecorder = recorder
    activeRecordingURL = url
    isRecorderAActive = isRecorderA
    
    let success = recorder.record()
    if !success {
      throw NSError(
        domain: Constants.errorDomain,
        code: Constants.recordingFailedCode,
        userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"]
      )
    }
    
    DebugLogger.logAudio("LIVE-MEETING: Started recording chunk \(chunkIndex) with recorder \(isRecorderA ? "A" : "B")")
  }
  
  private func createRecordingURL(isRecorderA: Bool) -> URL {
    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let suffix = isRecorderA ? "a" : "b"
    return documentsPath.appendingPathComponent("live_meeting_\(Date().timeIntervalSince1970)_\(suffix).wav")
  }
  
  private func createRecordingSettings() -> [String: Any] {
    return [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: Constants.sampleRate,
      AVNumberOfChannelsKey: Constants.numberOfChannels,
      AVLinearPCMBitDepthKey: Constants.bitDepth,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]
  }
  
  private func scheduleChunkTimer() {
    chunkTimer?.invalidate()
    chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: false) { [weak self] _ in
      self?.rotateAndDeliver()
    }
  }
  
  /// Rotates to the other recorder and delivers the completed chunk
  private func rotateAndDeliver() {
    guard isSessionActive else { return }
    
    DebugLogger.logAudio("LIVE-MEETING: Rotating recorders at chunk \(chunkIndex)")
    
    // Store references to current chunk data
    let completedChunkIndex = chunkIndex
    let completedChunkStartTime = currentChunkStartTime
    let completedRecordingURL = activeRecordingURL
    let wasRecorderAActive = isRecorderAActive
    
    // Calculate next chunk start time
    let nextChunkStartTime = (sessionStartTime != nil)
      ? Date().timeIntervalSince(sessionStartTime!)
      : currentChunkStartTime + chunkDuration
    
    // Start next recorder FIRST (to minimize gap)
    do {
      try startRecording(isRecorderA: !wasRecorderAActive)
      chunkIndex += 1
      currentChunkStartTime = nextChunkStartTime
      scheduleChunkTimer()
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to start next recorder: \(error)")
      delegate?.liveMeetingRecorder(didFailWithError: error)
      return
    }
    
    // THEN stop the completed recorder
    if wasRecorderAActive {
      recorderA?.stop()
    } else {
      recorderB?.stop()
    }
    
    // Deliver the completed chunk
    if let url = completedRecordingURL {
      DispatchQueue.main.async { [weak self] in
        self?.delegate?.liveMeetingRecorder(
          didFinishChunk: url,
          chunkIndex: completedChunkIndex,
          startTime: completedChunkStartTime
        )
      }
    }
  }
  
  /// Cleans up recorder resources
  private func cleanupRecorder(_ recorder: AVAudioRecorder?) {
    recorder?.stop()
  }
}

// MARK: - AVAudioRecorderDelegate

extension LiveMeetingRecorder: AVAudioRecorderDelegate {
  
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    let url = recorder.url
    
    // Clean up the recorder after a small delay to prevent CoreAudio issues
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      if recorder === self?.recorderA {
        self?.recorderA = nil
      } else if recorder === self?.recorderB {
        self?.recorderB = nil
      }
    }
    
    // If session is no longer active and this is the final chunk
    if !isSessionActive {
      if flag {
        // Verify file has content
        do {
          let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
          let fileSize = attributes[.size] as? Int64 ?? 0
          
          if fileSize > 0 {
            DebugLogger.log("LIVE-MEETING: Final chunk recorded successfully (\(fileSize) bytes)")
            // Calculate the start time for this final chunk
            let finalChunkStartTime = (sessionStartTime != nil)
              ? Date().timeIntervalSince(sessionStartTime!) - chunkDuration
              : currentChunkStartTime
            
            delegate?.liveMeetingRecorder(
              didFinishChunk: url,
              chunkIndex: chunkIndex,
              startTime: max(0, finalChunkStartTime)
            )
          } else {
            DebugLogger.logWarning("LIVE-MEETING: Final chunk is empty, skipping")
            try? FileManager.default.removeItem(at: url)
          }
        } catch {
          DebugLogger.logError("LIVE-MEETING: Failed to check final chunk: \(error)")
        }
      } else {
        DebugLogger.logError("LIVE-MEETING: Final chunk recording failed")
      }
    }
    // Note: For non-final chunks, delivery is handled in rotateAndDeliver()
  }
  
  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    if let error = error {
      DebugLogger.logError("LIVE-MEETING: Encode error: \(error)")
      delegate?.liveMeetingRecorder(didFailWithError: error)
    }
  }
}
