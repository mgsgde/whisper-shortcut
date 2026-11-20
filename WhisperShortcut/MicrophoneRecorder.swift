//
//  MicrophoneRecorder.swift
//  WhisperShortcut
//
//  One recorder surface for Dictate and Live Meeting. "System default" (and a chosen
//  device that is not connected) is an AVAudioRecorder, exactly as before. A chosen
//  device that is connected is an AVAudioEngine tap on that CoreAudio device, writing
//  the same 16-bit PCM WAV the callers already ask for.
//

import AudioToolbox
import AVFoundation
import Foundation

protocol MicrophoneRecorderDelegate: AnyObject {
  func microphoneRecorderDidFinishRecording(_ recorder: MicrophoneRecorder, successfully flag: Bool)
  func microphoneRecorderEncodeErrorDidOccur(_ recorder: MicrophoneRecorder, error: Error?)
}

protocol MicrophoneRecorder: AnyObject {
  var url: URL { get }
  var isRecording: Bool { get }
  var delegate: MicrophoneRecorderDelegate? { get set }
  func record() -> Bool
  func stop()
  func updateMeters()
  func averagePower(forChannel channel: Int) -> Float
}

enum MicrophoneRecorderFactory {

  /// `settings` is the AVAudioRecorder settings dictionary the callers already build.
  /// A missing device falls back to the system recorder and tells the user once.
  static func make(url: URL, settings: [String: Any]) throws -> MicrophoneRecorder {
    switch MicrophoneSelection.current() {
    case .systemDefault:
      logSystemDefault()
      return try SystemMicrophoneRecorder(url: url, settings: settings)
    case .missing(let uid):
      MicrophoneSelection.noteFallback(uid: uid)
      DebugLogger.logAudio(
        "AUDIO: Microphone = selected \(uid) not connected, falling back to system default")
      return try SystemMicrophoneRecorder(url: url, settings: settings)
    case .device(let device):
      DebugLogger.logAudio("AUDIO: Microphone = selected '\(device.name)' (\(device.uid))")
      return DeviceMicrophoneRecorder(url: url, settings: settings, device: device)
    }
  }

  private static func logSystemDefault() {
    if let device = AudioInputDeviceCatalog.defaultInputDevice() {
      DebugLogger.logAudio("AUDIO: Microphone = system default '\(device.name)' (\(device.uid))")
    } else {
      DebugLogger.logAudio("AUDIO: Microphone = system default")
    }
  }
}

// MARK: - System default

/// AVAudioRecorder, unchanged. Delegate callbacks are forwarded on the thread
/// AVAudioRecorder uses, which is what the existing recorders already handle.
final class SystemMicrophoneRecorder: NSObject, MicrophoneRecorder, AVAudioRecorderDelegate {
  let url: URL
  weak var delegate: MicrophoneRecorderDelegate?

  private let recorder: AVAudioRecorder

  init(url: URL, settings: [String: Any]) throws {
    self.url = url
    recorder = try AVAudioRecorder(url: url, settings: settings)
    super.init()
    recorder.isMeteringEnabled = true
    recorder.delegate = self
  }

  var isRecording: Bool { recorder.isRecording }

  func record() -> Bool { recorder.record() }

  func stop() { recorder.stop() }

  func updateMeters() { recorder.updateMeters() }

  func averagePower(forChannel channel: Int) -> Float {
    recorder.averagePower(forChannel: channel)
  }

  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    delegate?.microphoneRecorderDidFinishRecording(self, successfully: flag)
  }

  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    delegate?.microphoneRecorderEncodeErrorDidOccur(self, error: error)
  }
}

// MARK: - Chosen device

/// Captures one CoreAudio input through AVAudioEngine and writes the caller's WAV settings.
/// `record()` and `stop()` may run off the main thread (the dictate and meeting recorders
/// call them on a serial queue). The finish delegate is always delivered on the main queue,
/// and never from inside `stop()` itself.
final class DeviceMicrophoneRecorder: NSObject, MicrophoneRecorder {
  let url: URL
  weak var delegate: MicrophoneRecorderDelegate?

  private let settings: [String: Any]
  private let device: AudioInputDeviceCatalog.InputDevice
  private let targetFormat: AVAudioFormat?

  /// Engine graph, the tap flag, and `recording`. Never taken by the tap.
  private let graphLock = NSLock()
  /// The open file, the level, and the "already reported" flags. Taken by the tap.
  private let fileLock = NSLock()
  private let recoveryQueue = DispatchQueue(label: "com.whispershortcut.device-microphone-recorder")

  private var engine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var tapInstalled = false
  private var recording = false
  /// Bumped on stop so a configuration-change restart that lost the race does not start again.
  private var generation = 0
  private var configObserver: NSObjectProtocol?
  private var framesWritten: UInt64 = 0
  private var lastPowerDb: Float = -160
  /// Smoothed linear level of the meter. 0 is silence.
  private var meterLevel: Float = 0
  /// Peak of the partial ~10 ms window, carried across tap buffers.
  private var meterWindowPeak: Float = 0
  private var meterFrames: Int = 0
  private var didReportEncodeError = false
  private var didLogConvertError = false

  init(url: URL, settings: [String: Any], device: AudioInputDeviceCatalog.InputDevice) {
    self.url = url
    self.settings = settings
    self.device = device
    targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Self.sampleRate(from: settings),
      channels: Self.channelCount(from: settings),
      interleaved: false)
    super.init()
  }

  deinit {
    graphLock.lock()
    let shouldTearDown = recording || engine != nil || configObserver != nil
    recording = false
    generation += 1
    graphLock.unlock()
    if shouldTearDown {
      tearDownGraph()
      closeFile()
    }
  }

  var isRecording: Bool {
    graphLock.lock()
    defer { graphLock.unlock() }
    return recording
  }

  func record() -> Bool {
    graphLock.lock()
    if recording {
      graphLock.unlock()
      return true
    }
    do {
      try startLocked()
      graphLock.unlock()
      return true
    } catch {
      tearDownAssumingGraphLock()
      graphLock.unlock()
      DebugLogger.logError("AUDIO: Device microphone failed to start: \(error.logDescription)")
      return false
    }
  }

  func stop() {
    graphLock.lock()
    guard recording else {
      graphLock.unlock()
      return
    }
    recording = false
    generation += 1
    let frames = finishGraphLocked()
    graphLock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.microphoneRecorderDidFinishRecording(self, successfully: frames > 0)
    }
  }

  func updateMeters() {}

  func averagePower(forChannel channel: Int) -> Float {
    guard channel == 0 else { return -160 }
    fileLock.lock()
    defer { fileLock.unlock() }
    return lastPowerDb
  }

  // MARK: Start / stop

  /// Caller holds `graphLock`. Sets `recording` only after the engine is running.
  private func startLocked() throws {
    guard let targetFormat else { throw CaptureError.missingTargetFormat }
    let file = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    audioFile = file
    // Reset before start: the tap can write during `engine.start()`, and wiping the
    // counter afterwards would drop those frames from the "anything written" check.
    fileLock.lock()
    framesWritten = 0
    resetMeterLocked()
    didReportEncodeError = false
    didLogConvertError = false
    fileLock.unlock()
    let engine = AVAudioEngine()
    self.engine = engine
    try installCapture(on: engine, deviceID: device.id, targetFormat: targetFormat)
    recording = true
    installConfigurationObserver(for: engine)
  }

  /// Caller holds `graphLock`. Removes the tap, stops the engine, closes the file.
  /// Returns how many converted frames were written.
  private func finishGraphLocked() -> UInt64 {
    removeTapLocked()
    engine?.stop()
    engine = nil
    removeConfigurationObserverLocked()
    return closeFile()
  }

  /// Caller holds `graphLock`. Used when `record()` fails before `recording` is set.
  private func tearDownAssumingGraphLock() {
    removeTapLocked()
    engine?.stop()
    engine = nil
    removeConfigurationObserverLocked()
    _ = closeFile()
    recording = false
  }

  private func tearDownGraph() {
    graphLock.lock()
    removeTapLocked()
    engine?.stop()
    engine = nil
    removeConfigurationObserverLocked()
    graphLock.unlock()
  }

  private func removeTapLocked() {
    if tapInstalled, let engine {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
  }

  /// Closes the WAV so the header is finalized. Safe to call more than once.
  @discardableResult
  private func closeFile() -> UInt64 {
    fileLock.lock()
    defer { fileLock.unlock() }
    audioFile?.close()
    audioFile = nil
    resetMeterLocked()
    return framesWritten
  }

  // MARK: Device and tap

  /// Caller holds `graphLock`. The device is set before any format is read.
  private func installCapture(
    on engine: AVAudioEngine, deviceID: AudioObjectID, targetFormat: AVAudioFormat
  ) throws {
    guard let audioUnit = engine.inputNode.audioUnit else { throw CaptureError.missingAudioUnit }
    try setCurrentDevice(deviceID, on: audioUnit)
    let inputFormat = engine.inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw CaptureError.invalidInputFormat
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw CaptureError.converterUnavailable
    }
    converter.downmix = true
    engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) {
      [weak self] buffer, _ in
      self?.consume(buffer, converter: converter, targetFormat: targetFormat)
    }
    tapInstalled = true
    engine.prepare()
    try engine.start()
  }

  private func setCurrentDevice(_ id: AudioObjectID, on audioUnit: AudioUnit) throws {
    var deviceID = AudioDeviceID(id)
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &deviceID,
      UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else { throw CaptureError.setDeviceFailed(status) }
  }

  private func consume(
    _ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat
  ) {
    let inputRate = buffer.format.sampleRate
    guard inputRate > 0, buffer.frameLength > 0 else { return }
    let capacity = AVAudioFrameCount(
      ceil(Double(buffer.frameLength) * targetFormat.sampleRate / inputRate)) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
    output.frameLength = output.frameCapacity
    var provided = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      if provided {
        outStatus.pointee = .noDataNow
        return nil
      }
      provided = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, conversionError == nil else {
      logConvertErrorOnce(conversionError)
      return
    }

    fileLock.lock()
    updateMeterLocked(output)
    var reported: Error?
    if let audioFile, output.frameLength > 0 {
      do {
        try audioFile.write(from: output)
        framesWritten += UInt64(output.frameLength)
      } catch {
        if !didReportEncodeError {
          didReportEncodeError = true
          reported = error
        }
      }
    }
    fileLock.unlock()
    if let reported {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.microphoneRecorderEncodeErrorDidOccur(self, error: reported)
      }
    }
  }

  private func logConvertErrorOnce(_ error: NSError?) {
    fileLock.lock()
    let shouldLog = !didLogConvertError
    didLogConvertError = true
    fileLock.unlock()
    guard shouldLog else { return }
    let detail = error.map { $0.logDescription } ?? "unknown"
    DebugLogger.logError("AUDIO: Microphone conversion failed: \(detail)")
  }

  /// Peak of each ~10 ms window, then a fast attack (20 ms) and a slower release (50 ms),
  /// held across buffers. Plain full-buffer RMS measured a median 5.4 dB below
  /// AVAudioRecorder (built-in mic, 20 Hz, room noise; min 2.4, max 11.2). Smoothing
  /// that RMS left the crest-factor gap in place; the short-window peak is what tracks it.
  private static let meterWindowSeconds: Double = 0.010
  private static let meterAttackSeconds: Double = 0.020
  private static let meterReleaseSeconds: Double = 0.050

  /// Caller holds `fileLock`.
  private func resetMeterLocked() {
    meterLevel = 0
    meterWindowPeak = 0
    meterFrames = 0
    lastPowerDb = -160
  }

  /// Caller holds `fileLock`. A short tail is closed too, so a peak at the end of a tap
  /// buffer is not held back until the next callback.
  private func updateMeterLocked(_ buffer: AVAudioPCMBuffer) {
    let frames = Int(buffer.frameLength)
    guard frames > 0, let samples = buffer.floatChannelData?[0] else { return }
    let sampleRate = buffer.format.sampleRate
    guard sampleRate > 0 else { return }
    let window = max(1, Int((sampleRate * Self.meterWindowSeconds).rounded()))
    for index in 0..<frames {
      let sample = abs(samples[index])
      if sample > meterWindowPeak { meterWindowPeak = sample }
      meterFrames += 1
      if meterFrames == window {
        closeMeterWindowLocked(sampleRate: sampleRate)
      }
    }
    if meterFrames > 0 {
      closeMeterWindowLocked(sampleRate: sampleRate)
    }
    lastPowerDb = meterLevel > 0 ? max(20 * log10(meterLevel), -160) : -160
  }

  /// Caller holds `fileLock`.
  private func closeMeterWindowLocked(sampleRate: Double) {
    let peak = meterWindowPeak
    let dt = Double(meterFrames) / sampleRate
    meterWindowPeak = 0
    meterFrames = 0
    guard dt > 0 else { return }
    let tau = peak > meterLevel ? Self.meterAttackSeconds : Self.meterReleaseSeconds
    let alpha = Float(1 - exp(-dt / tau))
    meterLevel += alpha * (peak - meterLevel)
  }

  // MARK: Device lost mid-recording

  private func installConfigurationObserver(for engine: AVAudioEngine) {
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      // The notification is delivered on an engine queue that deadlocks if the engine
      // is torn down inline. Hop off it before touching the graph.
      self?.recoveryQueue.async {
        self?.recoverFromConfigurationChange()
      }
    }
  }

  private func removeConfigurationObserverLocked() {
    if let configObserver {
      NotificationCenter.default.removeObserver(configObserver)
      self.configObserver = nil
    }
  }

  /// The engine has already stopped itself when this notification is a real hardware
  /// change. A notification that arrives while we are running is the echo of our own
  /// restart, and restarting again would loop.
  private func recoverFromConfigurationChange() {
    graphLock.lock()
    guard recording, let engine, engine.isRunning == false else {
      graphLock.unlock()
      return
    }
    let generation = self.generation
    removeTapLocked()
    graphLock.unlock()

    let deviceID: AudioObjectID
    let switchedToDefault: Bool
    if AudioInputDeviceCatalog.isAlive(device.id) {
      deviceID = device.id
      switchedToDefault = false
    } else if let fallback = AudioInputDeviceCatalog.defaultInputDeviceID() {
      deviceID = fallback
      switchedToDefault = true
    } else {
      DebugLogger.logError(
        "AUDIO: Selected microphone disconnected and the system default input is unavailable")
      stop()
      return
    }

    do {
      let outcome = try restartCapture(on: engine, deviceID: deviceID, generation: generation)
      guard outcome == .restarted else { return }
    } catch {
      DebugLogger.logError("AUDIO: Restarting the selected microphone failed: \(error.logDescription)")
      stop()
      return
    }

    graphLock.lock()
    let stillRecording = recording
    graphLock.unlock()
    if switchedToDefault, stillRecording {
      DebugLogger.logAudio(
        "AUDIO: Selected microphone disconnected mid-recording, continuing on system default")
      MicrophoneSelection.noteFallback(uid: device.uid)
    }
  }

  private func restartCapture(
    on engine: AVAudioEngine, deviceID: AudioObjectID, generation: Int
  ) throws -> RestartOutcome {
    graphLock.lock()
    defer { graphLock.unlock() }
    guard recording, self.generation == generation else { return .cancelled }
    guard let targetFormat else { throw CaptureError.missingTargetFormat }
    // Same file: the tap was removed above, so nothing is writing while we retarget.
    try installCapture(on: engine, deviceID: deviceID, targetFormat: targetFormat)
    guard recording, self.generation == generation else {
      removeTapLocked()
      engine.stop()
      return .cancelled
    }
    return .restarted
  }

  private enum RestartOutcome {
    case restarted
    case cancelled
  }

  private enum CaptureError: Error, CustomStringConvertible {
    case missingTargetFormat
    case missingAudioUnit
    case invalidInputFormat
    case converterUnavailable
    case setDeviceFailed(OSStatus)

    var description: String {
      switch self {
      case .missingTargetFormat: return "invalid target audio format"
      case .missingAudioUnit: return "input node has no audio unit"
      case .invalidInputFormat: return "input format is not usable"
      case .converterUnavailable: return "could not create audio converter"
      case .setDeviceFailed(let status): return "setting the input device failed (\(status))"
      }
    }
  }

  private static func sampleRate(from settings: [String: Any]) -> Double {
    if let value = settings[AVSampleRateKey] as? Double { return value }
    if let value = settings[AVSampleRateKey] as? NSNumber { return value.doubleValue }
    return 24000
  }

  private static func channelCount(from settings: [String: Any]) -> AVAudioChannelCount {
    if let value = settings[AVNumberOfChannelsKey] as? Int { return AVAudioChannelCount(value) }
    if let value = settings[AVNumberOfChannelsKey] as? NSNumber {
      return AVAudioChannelCount(value.uint32Value)
    }
    return 1
  }
}
