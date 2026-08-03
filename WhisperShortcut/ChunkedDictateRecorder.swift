import AVFoundation
import Foundation

/// Chunk-capable Dictate recorder — slice 1 of plans/active/streaming-dictate.md.
///
/// Records through double-buffered AVAudioRecorders that rotate ONLY at silence
/// boundaries (≥ `AppConstants.dictateChunkSilenceDuration` below the threshold, after
/// `AppConstants.dictateChunkMinDuration`), mirroring LiveMeetingRecorder's proven
/// pattern. There is deliberately no max-duration cut: continuous speech simply keeps
/// growing the current chunk, so seams only ever sit inside real pauses.
///
/// In this slice the chunks are merged back into a single WAV on stop and delivered
/// through the same `AudioRecorderDelegate` contract as `AudioRecorder` — externally
/// identical behavior. Slice 2 will consume `onChunkFinalized` to transcribe chunks
/// while the user is still speaking.
class ChunkedDictateRecorder: NSObject, DictationAudioRecording {
  weak var delegate: AudioRecorderDelegate?

  /// Called on the main thread with every metering sample (~20 Hz); drives the
  /// recording indicator's level bars (same contract as `AudioRecorder.onLevelSample`).
  var onLevelSample: ((Float) -> Void)?

  /// Fires on the main thread whenever a chunk is rotated out mid-recording, with the
  /// chunk's URL, index, and whether it was fully silent (peak below the threshold).
  /// DictateStreamingSession consumes this to transcribe chunks while the user speaks.
  var onChunkFinalized: ((URL, Int, Bool) -> Void)?

  /// Fires on the main thread at stop with the tail chunk (the recording since the last
  /// rotation), before the merged WAV is delivered to the delegate. Only meaningful when
  /// at least one rotation happened — single-chunk sessions never call this.
  var onFinalChunk: ((URL, Int, Bool) -> Void)?

  // MARK: - Constants
  private enum Constants {
    static let sampleRate: Double = 24000.0
    static let numberOfChannels = 1
    static let bitDepth = 16
    static let errorDomain = "WhisperShortcut"
    static let permissionDeniedCode = 1001
    static let recordingFailedCode = 1002
    static let recordingUnsuccessfulCode = 1003
    static let emptyFileCode = 1004
  }

  private static let silenceThresholdDB: Float = -45
  /// Metering runs at 20 Hz to drive the live level bars in the recording indicator.
  private static let meteringInterval: TimeInterval = 0.05
  /// Silence-tail and rotation logic run at the 0.2s cadence AudioRecorder was tuned for.
  private static let silenceSampleDecimation = 4
  /// Decimated samples of continuous silence needed to rotate a chunk out.
  private static let rotationSilenceSamplesNeeded = max(
    1,
    Int(
      ceil(
        AppConstants.dictateChunkSilenceDuration
          / (meteringInterval * Double(silenceSampleDecimation)))))

  /// `AVAudioRecorder.record()` and `.stop()` both block on CoreAudio's I/O thread —
  /// `AudioQueueXPC_Bridge::Start` and `AQ::API::Queue::AwaitAllPendingCallbacks` have each
  /// been caught wedging the main thread for seconds in watchdog hang captures. They run
  /// here instead. The queue is serial on purpose: rotation enqueues the new recorder's
  /// `record()` before the old one's `stop()`, and that order is what keeps capture gap-free.
  private let audioQueue = DispatchQueue(
    label: "com.whispershortcut.chunked-dictate-recorder", qos: .userInitiated)

  // MARK: - State
  private var recorderA: AVAudioRecorder?
  private var recorderB: AVAudioRecorder?
  private var activeRecorder: AVAudioRecorder?
  private var isRecorderAActive = true
  private var isSessionActive = false

  /// URLs of all chunks recorded this session, in order (the active one is appended on stop).
  private var chunkURLs: [URL] = []
  /// The merged file delivered to the delegate (deleted in `cleanup()`).
  private var mergedURL: URL?

  private var meteringTimer: Timer?
  private var meteringTickCount = 0
  private var peakPowerDuringRecording: Float = -160
  /// Peak within the current chunk only; reset at rotation. Lets consumers skip
  /// transcribing fully-silent chunks.
  private var peakPowerDuringChunk: Float = -160
  private var lastTwoMeterSamples: (Float, Float) = (-160, -160)
  private var meterSampleCount = 0
  private var consecutiveSilenceSamples = 0
  private var currentChunkWallStart: Date?

  private(set) var lastRecordingWasSilent: Bool = false

  var hasRecentlyBeenSilent: Bool {
    meterSampleCount >= 2
      && lastTwoMeterSamples.0 < Self.silenceThresholdDB
      && lastTwoMeterSamples.1 < Self.silenceThresholdDB
  }

  override init() {
    super.init()
    DebugLogger.logAudio("🎵 AUDIO: ChunkedDictateRecorder init")
  }

  // MARK: - Public

  func startRecording() {
    requestMicrophonePermission { [weak self] granted in
      guard let self else { return }
      if granted {
        self.beginSession()
      } else {
        let error = NSError(
          domain: Constants.errorDomain, code: Constants.permissionDeniedCode,
          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        self.delegate?.audioRecorderDidFailWithError(error)
      }
    }
  }

  func stopRecording() {
    meteringTimer?.invalidate()
    meteringTimer = nil

    // Deliberately not gated on `recorder.isRecording`: a stop that lands in the window
    // before the async `record()` has flipped that flag must still end the session.
    // `isSessionActive` is our own state and is the authoritative signal.
    guard isSessionActive, let recorder = activeRecorder else { return }
    isSessionActive = false

    lastRecordingWasSilent = peakPowerDuringRecording < Self.silenceThresholdDB
    DebugLogger.logAudio(
      "AUDIO: Recording peak \(String(format: "%.1f", peakPowerDuringRecording)) dB, threshold \(Self.silenceThresholdDB) dB, silent=\(lastRecordingWasSilent), chunks=\(chunkURLs.count + 1)"
    )

    // Queued behind any in-flight record()/stop(), so it can never overtake a rotation.
    // Final delivery continues in audioRecorderDidFinishRecording.
    audioQueue.async { recorder.stop() }
  }

  func cleanup() {
    meteringTimer?.invalidate()
    meteringTimer = nil
    isSessionActive = false
    // Stops go to audioQueue; the closure's own strong refs keep the recorders alive past
    // the nil-out below. The files deleted here are already-rotated chunks — never the
    // recorder's own open file — so the deletion does not race the stop.
    let live = [recorderA, recorderB].compactMap { $0 }
    if !live.isEmpty {
      audioQueue.async { live.forEach { $0.stop() } }
    }
    recorderA = nil
    recorderB = nil
    activeRecorder = nil
    for url in chunkURLs {
      try? FileManager.default.removeItem(at: url)
    }
    chunkURLs = []
    if let url = mergedURL {
      try? FileManager.default.removeItem(at: url)
    }
    mergedURL = nil
  }

  // MARK: - Session

  private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { completion(granted) }
      }
    case .denied, .restricted:
      DebugLogger.logWarning("Microphone permission denied or restricted")
      completion(false)
    @unknown default:
      completion(false)
    }
  }

  private func beginSession() {
    // Remove the previous session's files (chunks aren't individually delivered to the
    // delegate, so nobody else cleans them up). Any in-flight streaming reads of these
    // files finished long before a new recording can start.
    for url in chunkURLs {
      try? FileManager.default.removeItem(at: url)
    }
    if let url = mergedURL {
      try? FileManager.default.removeItem(at: url)
    }
    chunkURLs = []
    mergedURL = nil
    peakPowerDuringRecording = -160
    peakPowerDuringChunk = -160
    lastTwoMeterSamples = (-160, -160)
    meterSampleCount = 0
    meteringTickCount = 0
    consecutiveSilenceSamples = 0
    lastRecordingWasSilent = false
    isSessionActive = true

    do {
      try startChunkRecorder(isRecorderA: true)
    } catch {
      isSessionActive = false
      delegate?.audioRecorderDidFailWithError(error)
      return
    }

    meteringTimer = Timer.scheduledTimer(
      withTimeInterval: Self.meteringInterval, repeats: true
    ) { [weak self] _ in
      self?.sampleMetering()
    }
  }

  /// Builds a configured recorder. Allocation is cheap and its failure is the one the
  /// callers can still recover from, so it stays synchronous and keeps throwing; only the
  /// blocking `record()` moves to `audioQueue` (see `startChunkRecorder`).
  private func makeChunkRecorder() throws -> AVAudioRecorder {
    let documentsPath =
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let url = documentsPath.appendingPathComponent(
      "recording_\(Date().timeIntervalSince1970)_chunk\(chunkURLs.count).wav")

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: Constants.sampleRate,
      AVNumberOfChannelsKey: Constants.numberOfChannels,
      AVLinearPCMBitDepthKey: Constants.bitDepth,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.delegate = self
    recorder.isMeteringEnabled = true
    return recorder
  }

  /// Commits the new recorder as active immediately, then starts it on `audioQueue`.
  /// Committing first keeps `sampleMetering` and `rotateChunk` reading consistent state
  /// without having to wait on CoreAudio; the metering guard simply skips the handful of
  /// ticks before `isRecording` flips true.
  private func startChunkRecorder(isRecorderA: Bool) throws {
    let recorder = try makeChunkRecorder()

    if isRecorderA { recorderA = recorder } else { recorderB = recorder }
    activeRecorder = recorder
    isRecorderAActive = isRecorderA
    currentChunkWallStart = Date()
    consecutiveSilenceSamples = 0

    audioQueue.async { [weak self] in
      guard !recorder.record() else { return }
      DispatchQueue.main.async {
        guard let self, self.activeRecorder === recorder, self.isSessionActive else { return }
        let error = NSError(
          domain: Constants.errorDomain, code: Constants.recordingFailedCode,
          userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"])
        DebugLogger.logError("AUDIO: Chunk recorder failed to start: \(error.localizedDescription)")
        self.meteringTimer?.invalidate()
        self.meteringTimer = nil
        self.isSessionActive = false
        self.delegate?.audioRecorderDidFailWithError(error)
      }
    }
  }

  // MARK: - Metering & rotation

  private func sampleMetering() {
    guard let recorder = activeRecorder, recorder.isRecording else { return }
    recorder.updateMeters()
    let power = recorder.averagePower(forChannel: 0)
    if power > peakPowerDuringRecording { peakPowerDuringRecording = power }
    if power > peakPowerDuringChunk { peakPowerDuringChunk = power }
    onLevelSample?(power)

    meteringTickCount += 1
    guard meteringTickCount % Self.silenceSampleDecimation == 0 else { return }

    lastTwoMeterSamples = (lastTwoMeterSamples.1, power)
    meterSampleCount += 1

    guard isSessionActive, let wallStart = currentChunkWallStart,
      Date().timeIntervalSince(wallStart) >= AppConstants.dictateChunkMinDuration
    else { return }

    if power < Self.silenceThresholdDB {
      consecutiveSilenceSamples += 1
      if consecutiveSilenceSamples >= Self.rotationSilenceSamplesNeeded {
        rotateChunk()
      }
    } else {
      consecutiveSilenceSamples = 0
    }
  }

  /// Starts the other recorder, then stops the current one and records its URL as a
  /// completed chunk. Start-before-stop keeps the capture gap-free; the seam sits inside
  /// the detected pause, so a few overlapping milliseconds of silence are harmless.
  private func rotateChunk() {
    guard isSessionActive, let current = activeRecorder else { return }
    let completedURL = current.url
    let completedIndex = chunkURLs.count
    let completedWasSilent = peakPowerDuringChunk < Self.silenceThresholdDB
    let wasRecorderAActive = isRecorderAActive

    do {
      try startChunkRecorder(isRecorderA: !wasRecorderAActive)
    } catch {
      // Keep recording on the current chunk; rotation is an optimization, not a requirement.
      DebugLogger.logError("AUDIO: Chunk rotation failed, continuing current chunk: \(error.localizedDescription)")
      consecutiveSilenceSamples = 0
      return
    }

    peakPowerDuringChunk = -160
    chunkURLs.append(completedURL)

    // `stop()` lands on `audioQueue` behind the new recorder's `record()`, so the seam stays
    // gap-free. `onChunkFinalized` waits for it to return: stop() is what closes the WAV, and
    // DictateStreamingSession starts reading that file the moment it is told about it.
    audioQueue.async { [weak self] in
      current.stop()
      DispatchQueue.main.async {
        guard let self else { return }
        DebugLogger.logAudio(
          "AUDIO: Rotated dictate chunk \(completedIndex) at silence boundary (silent=\(completedWasSilent), \(completedURL.lastPathComponent))")
        self.onChunkFinalized?(completedURL, completedIndex, completedWasSilent)
      }
    }
  }

  // MARK: - Final delivery

  /// Merges the session's chunk WAVs into one file. Single-chunk sessions (the common
  /// case for short dictations) skip merging and deliver the chunk untouched.
  private func mergeChunks(_ urls: [URL]) throws -> URL {
    guard urls.count > 1 else { return urls[0] }

    let outputURL = (urls[0].deletingLastPathComponent())
      .appendingPathComponent("recording_\(Date().timeIntervalSince1970)_merged.wav")
    guard let firstFile = try? AVAudioFile(forReading: urls[0]) else {
      throw NSError(
        domain: Constants.errorDomain, code: Constants.recordingUnsuccessfulCode,
        userInfo: [NSLocalizedDescriptionKey: "Could not read first chunk for merging"])
    }
    let output = try AVAudioFile(
      forWriting: outputURL,
      settings: firstFile.fileFormat.settings,
      commonFormat: firstFile.processingFormat.commonFormat,
      interleaved: firstFile.processingFormat.isInterleaved
    )
    for url in urls {
      let source = try AVAudioFile(forReading: url)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: source.processingFormat, frameCapacity: 65_536)
      else { continue }
      while source.framePosition < source.length {
        try source.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        try output.write(from: buffer)
      }
    }
    output.close()
    return outputURL
  }

  private func finalizeSession(finalChunkURL: URL) {
    // Hand the tail chunk to the streaming session BEFORE merging, so its transcription
    // runs in parallel with the merge. Only fires when rotations happened — single-chunk
    // recordings take the plain path.
    if !chunkURLs.isEmpty {
      let tailWasSilent = peakPowerDuringChunk < Self.silenceThresholdDB
      onFinalChunk?(finalChunkURL, chunkURLs.count, tailWasSilent)
    }
    chunkURLs.append(finalChunkURL)
    let urls = chunkURLs

    do {
      let deliveredURL = try mergeChunks(urls)
      let fileSize =
        (try FileManager.default.attributesOfItem(atPath: deliveredURL.path)[.size] as? Int64) ?? 0
      guard fileSize > 0 else {
        throw NSError(
          domain: Constants.errorDomain, code: Constants.emptyFileCode,
          userInfo: [NSLocalizedDescriptionKey: "Recording file is empty"])
      }
      if urls.count > 1 {
        mergedURL = deliveredURL
        DebugLogger.logAudio(
          "AUDIO: Merged \(urls.count) dictate chunks into \(deliveredURL.lastPathComponent) (\(fileSize) bytes)")
      }
      delegate?.audioRecorderDidFinishRecording(audioURL: deliveredURL)
    } catch {
      DebugLogger.logError("AUDIO: Finalizing dictate recording failed: \(error.localizedDescription)")
      delegate?.audioRecorderDidFailWithError(error)
    }
  }
}

// MARK: - AVAudioRecorderDelegate
extension ChunkedDictateRecorder: AVAudioRecorderDelegate {
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    // Deferred release, identity-checked — same CoreAudio I/O-cycle courtesy as AudioRecorder.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak recorder] in
      guard let self, let recorder else { return }
      if self.recorderA === recorder { self.recorderA = nil }
      if self.recorderB === recorder { self.recorderB = nil }
      if self.activeRecorder === recorder, !self.isSessionActive { self.activeRecorder = nil }
    }

    // Mid-session stops are rotated-out chunks; their URLs are already tracked.
    guard !isSessionActive, recorder === activeRecorder else { return }

    let url = recorder.url
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if flag {
        self.finalizeSession(finalChunkURL: url)
      } else {
        let error = NSError(
          domain: Constants.errorDomain, code: Constants.recordingUnsuccessfulCode,
          userInfo: [NSLocalizedDescriptionKey: "Recording finished unsuccessfully"])
        self.delegate?.audioRecorderDidFailWithError(error)
      }
    }
  }

  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    if let error {
      delegate?.audioRecorderDidFailWithError(error)
    }
  }
}
