import AVFoundation
import Foundation

/// Delegate protocol for receiving live meeting recording events
protocol LiveMeetingRecorderDelegate: AnyObject {
  /// Called when a chunk has finished recording and is ready for transcription
  func liveMeetingRecorder(didFinishChunk audioURL: URL, chunkIndex: Int, startTime: TimeInterval)

  /// Called when recording fails
  func liveMeetingRecorder(didFailWithError error: Error)
}

/// Double-buffer audio recorder for seamless live meeting transcription.
/// Uses two AVAudioRecorder instances that alternate to ensure no audio is lost.
/// Chunks are split at silence boundaries (pause ≥ 1.5s) with a fallback max duration.
class LiveMeetingRecorder: NSObject {

  // MARK: - Constants
  private enum Constants {
    static let sampleRate: Double = 24000.0
    static let numberOfChannels = 1
    static let bitDepth = 16
    static let errorDomain = "LiveMeetingRecorder"
    static let permissionDeniedCode = 2001
  }

  // MARK: - Properties
  weak var delegate: LiveMeetingRecorderDelegate?

  /// Maximum chunk duration (fallback if no silence detected)
  private let maxChunkDuration: TimeInterval
  /// Minimum chunk duration before silence-based rotation is allowed
  private let minChunkDuration: TimeInterval
  /// How long silence must last to trigger rotation
  private let silenceDuration: TimeInterval
  /// dB threshold below which audio is considered silence
  private let silenceThresholdDB: Float
  /// How often to poll audio metering
  private let meteringInterval: TimeInterval

  /// Double-buffer recorders
  private var recorderA: AVAudioRecorder?
  private var recorderB: AVAudioRecorder?

  /// Currently active recorder (points to A or B)
  private var activeRecorder: AVAudioRecorder?

  /// URL for currently recording audio
  private var activeRecordingURL: URL?

  /// Hard-max fallback timer
  private var chunkTimer: Timer?

  /// Fast-polling timer for silence detection
  private var meteringTimer: Timer?

  /// Current chunk index
  private var chunkIndex: Int = 0

  /// Session start time for calculating timestamps
  private var sessionStartTime: Date?

  /// Current chunk start time (relative to session start)
  private var currentChunkStartTime: TimeInterval = 0

  /// When the current chunk started recording (wall clock)
  private var currentChunkWallStart: Date?

  /// Flag indicating if session is active
  private(set) var isSessionActive: Bool = false

  /// Flag indicating which recorder is active (true = A, false = B)
  private var isRecorderAActive: Bool = true

  /// Consecutive silence samples counter
  private var consecutiveSilenceSamples: Int = 0

  /// Number of silence samples needed to trigger rotation
  private var silenceSamplesNeeded: Int {
    max(1, Int(ceil(silenceDuration / meteringInterval)))
  }

  // MARK: - Initialization

  init(
    maxChunkDuration: TimeInterval = AppConstants.liveMeetingChunkIntervalDefault,
    minChunkDuration: TimeInterval = AppConstants.liveMeetingChunkMinDuration,
    silenceDuration: TimeInterval = AppConstants.liveMeetingSilenceDuration,
    silenceThresholdDB: Float = AppConstants.liveMeetingSilenceThresholdDB,
    meteringInterval: TimeInterval = AppConstants.liveMeetingMeteringInterval
  ) {
    self.maxChunkDuration = maxChunkDuration
    self.minChunkDuration = minChunkDuration
    self.silenceDuration = silenceDuration
    self.silenceThresholdDB = silenceThresholdDB
    self.meteringInterval = meteringInterval
    super.init()
  }

  // MARK: - Public Methods

  /// Starts a new live meeting recording session
  func startSession() {
    DebugLogger.log("LIVE-MEETING: Starting session (max=\(maxChunkDuration)s, min=\(minChunkDuration)s, silence=\(silenceDuration)s)")

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
    meteringTimer?.invalidate()
    meteringTimer = nil

    if let activeRecorder = activeRecorder, activeRecorder.isRecording {
      activeRecorder.stop()
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
      self.currentChunkWallStart = Date()
      self.consecutiveSilenceSamples = 0
      self.isSessionActive = true
      self.isRecorderAActive = true

      do {
        try self.startRecording(isRecorderA: true)
        self.scheduleTimers()
      } catch {
        DebugLogger.logError("LIVE-MEETING: Failed to start session: \(error)")
        self.delegate?.liveMeetingRecorder(didFailWithError: error)
        return
      }
    }
  }

  private func startRecording(isRecorderA: Bool) throws {
    let url = createRecordingURL(isRecorderA: isRecorderA)
    let settings = createRecordingSettings()

    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.delegate = self
    recorder.isMeteringEnabled = true

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
      throw LiveMeetingRecorderError.recordingFailed(reason: "Failed to start recording")
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

  private func scheduleTimers() {
    chunkTimer?.invalidate()
    meteringTimer?.invalidate()
    consecutiveSilenceSamples = 0

    chunkTimer = Timer.scheduledTimer(withTimeInterval: maxChunkDuration, repeats: false) { [weak self] _ in
      guard let self, self.isSessionActive else { return }
      DebugLogger.logAudio("LIVE-MEETING: Max chunk duration reached, rotating")
      self.rotateAndDeliver()
    }

    meteringTimer = Timer.scheduledTimer(withTimeInterval: meteringInterval, repeats: true) { [weak self] _ in
      self?.checkSilence()
    }
  }

  private func checkSilence() {
    guard isSessionActive, let recorder = activeRecorder, recorder.isRecording else { return }

    guard let wallStart = currentChunkWallStart else { return }
    let elapsed = Date().timeIntervalSince(wallStart)
    guard elapsed >= minChunkDuration else { return }

    recorder.updateMeters()
    let power = recorder.averagePower(forChannel: 0)

    if power < silenceThresholdDB {
      consecutiveSilenceSamples += 1
      if consecutiveSilenceSamples >= silenceSamplesNeeded {
        DebugLogger.logAudio("LIVE-MEETING: Silence detected after \(String(format: "%.0f", elapsed))s, rotating")
        rotateAndDeliver()
      }
    } else {
      consecutiveSilenceSamples = 0
    }
  }

  /// Rotates to the other recorder and delivers the completed chunk
  private func rotateAndDeliver() {
    guard isSessionActive else { return }

    let completedChunkIndex = chunkIndex
    let completedChunkStartTime = currentChunkStartTime
    let completedRecordingURL = activeRecordingURL
    let wasRecorderAActive = isRecorderAActive

    let nextChunkStartTime = (sessionStartTime != nil)
      ? Date().timeIntervalSince(sessionStartTime!)
      : currentChunkStartTime + maxChunkDuration

    do {
      try startRecording(isRecorderA: !wasRecorderAActive)
      chunkIndex += 1
      currentChunkStartTime = nextChunkStartTime
      currentChunkWallStart = Date()
      scheduleTimers()
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to start next recorder: \(error)")
      delegate?.liveMeetingRecorder(didFailWithError: error)
      return
    }

    if wasRecorderAActive {
      recorderA?.stop()
    } else {
      recorderB?.stop()
    }

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

  private func cleanupRecorder(_ recorder: AVAudioRecorder?) {
    recorder?.stop()
  }
}

// MARK: - AVAudioRecorderDelegate

extension LiveMeetingRecorder: AVAudioRecorderDelegate {

  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    let url = recorder.url

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      if recorder === self?.recorderA {
        self?.recorderA = nil
      } else if recorder === self?.recorderB {
        self?.recorderB = nil
      }
    }

    if !isSessionActive {
      if flag {
        do {
          let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
          let fileSize = attributes[.size] as? Int64 ?? 0

          if fileSize > 0 {
            DebugLogger.log("LIVE-MEETING: Final chunk recorded successfully (\(fileSize) bytes)")
            let finalChunkStartTime = (sessionStartTime != nil)
              ? Date().timeIntervalSince(sessionStartTime!) - (Date().timeIntervalSince(currentChunkWallStart ?? Date()))
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
  }

  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    if let error = error {
      DebugLogger.logError("LIVE-MEETING: Encode error: \(error)")
      delegate?.liveMeetingRecorder(didFailWithError: error)
    }
  }
}
