import AVFoundation
import Foundation

/// Runs the live text panel for one Dictate recording (plans/active/live-dictate-preview.md, S2).
///
/// `MenuBarController` calls `startIfEnabled` once capture has begun and `stop` whenever the app
/// leaves Dictate recording — Stop, ✕, Fn-discard, a failed recording. Everything here is a
/// preview and fails closed: any error logs, hides the panel and ends the preview, and nothing it
/// does reaches the dictation. The recorder (`ChunkedDictateRecorder`) and the final transcript
/// path do not know it exists. The one shared resource, the model load, is shielded from the
/// preview's cancellation (`LocalSpeechService.parakeetBackendForLivePreview`).
///
/// With the setting off, `startIfEnabled` returns at its first line: no model call, no
/// `AVAudioEngine`, no panel, and the Glossary is not even read.
///
/// Main thread only.
final class LiveDictatePreviewController {
  private let tap = LiveDictateAudioTap()
  private var preview: ParakeetLivePreview?
  private var startTask: Task<Void, Never>?
  /// Identifies the running session; callbacks from an older one are dropped. Nil when idle.
  private var session: UUID?
  private var confirmed = ""
  private var volatile = ""
  private var stats = Stats()
  /// The last preview text of a stopped session, kept until the pasted transcript arrives so the
  /// drift between the two can be logged (`noteFinalTranscript`). Cleared by the next start.
  private var pendingDriftText: String?

  /// What the `LIVE-PREVIEW:` summary line reports (plan, Design 6).
  private struct Stats {
    var started = Date()
    /// When the tap delivered its first buffer; window lag is measured from here.
    var audioStarted: Date?
    var windows = 0
    var totalLagMs: Double = 0
    var maxLagMs: Double = 0
    var errors = 0
    var tapRestarts = 0
  }

  /// - Parameters:
  ///   - vocabulary: the Glossary terms the final Parakeet decode boosts (`SpeechService.glossaryKeywords`).
  func startIfEnabled(vocabulary: @autoclosure () -> [String]) {
    pendingDriftText = nil  // a new recording: an older preview has nothing to compare with
    guard LiveDictatePreviewSetting.isEnabled else { return }
    stop()
    pendingDriftText = nil
    let model = TranscriptionModel.loadSelected()
    guard
      LiveDictatePreviewSetting.shouldStart(
        enabled: true, model: model, downloaded: model.isOfflineModelAvailable()),
      let modelType = model.offlineModelType
    else {
      DebugLogger.log("LIVE-PREVIEW: Not started — needs Apple Silicon and a downloaded Parakeet as the Dictate model")
      return
    }

    let session = UUID()
    self.session = session
    confirmed = ""
    volatile = ""
    stats = Stats()
    let language = Self.dictateLanguageCode()
    let terms = vocabulary()
    DebugLogger.log(
      "LIVE-PREVIEW: Starting (language=\(language ?? "auto"), glossaryTerms=\(terms.count), hop=\(ParakeetLivePreview.hopSeconds)s)")

    // Audio first: buffers queue in the preview while the model loads and the engine is built,
    // so the opening words are not lost.
    let preview = ParakeetLivePreview()
    self.preview = preview
    startTap(feeding: preview, session: session)

    startTask = Task { [weak self] in
      do {
        let backend = try await LocalSpeechService.shared.parakeetBackendForLivePreview(modelType)
        try await preview.connect(to: backend, language: language, vocabulary: terms) { confirmed, volatile in
          DispatchQueue.main.async { self?.handleText(confirmed: confirmed, volatile: volatile, session: session) }
        }
      } catch {
        await MainActor.run { self?.fail(stage: "load", error: error, session: session) }
      }
    }
  }

  /// Ends the preview and hides the panel. Idempotent; safe to call when nothing runs.
  func stop() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.stop() }
      return
    }
    guard let session else { return }
    self.session = nil
    startTask?.cancel()
    startTask = nil
    tap.stop()
    preview?.stop()
    preview = nil
    LiveDictatePanel.shared.hide()
    logSummary(session: session)
    let text = [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    pendingDriftText = text.isEmpty ? nil : text
  }

  /// The pasted Dictate transcript. Logs how far the last preview was from it, as word counts
  /// only, and forgets both. A no-op when no preview ran for this recording.
  func noteFinalTranscript(_ text: String) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.noteFinalTranscript(text) }
      return
    }
    guard let preview = pendingDriftText else { return }
    pendingDriftText = nil
    let drift = LiveDictatePreviewText.drift(preview: preview, final: text)
    DebugLogger.log(
      "LIVE-PREVIEW: drift previewWords=\(drift.previewWords) finalWords=\(drift.finalWords) "
        + "wordEditDistance=\(drift.editDistance)")
  }

  // MARK: - Steps

  private func startTap(feeding preview: ParakeetLivePreview, session: UUID) {
    tap.start(
      onFirstBuffer: { [weak self] in
        guard let self, self.session == session else { return }
        self.stats.audioStarted = Date()
      },
      onBuffer: { buffer in preview.append(buffer) },
      onRestart: { [weak self] in
        guard let self, self.session == session else { return }
        self.stats.tapRestarts += 1
      },
      onFailure: { [weak self] error in
        self?.fail(stage: "audio", error: error, session: session)
      })
  }

  private func handleText(confirmed: String, volatile: String, session: UUID) {
    guard self.session == session else { return }
    self.confirmed = confirmed
    self.volatile = volatile
    recordLag()
    let shown = LiveDictatePreviewText.displayTail(committed: confirmed, tentative: volatile)
    guard !shown.committed.isEmpty || !shown.tentative.isEmpty else { return }
    // Shown with the first words, not at the start: most short dictations end before the first
    // window (~6 s) and would only flash an empty panel.
    if !LiveDictatePanel.shared.isVisible { LiveDictatePanel.shared.show() }
    LiveDictatePanel.shared.update(committed: shown.committed, tentative: shown.tentative)
  }

  /// Window `n` (0-based) can be decoded once `(n + 1) × hop + right context` seconds of audio
  /// exist. The time past that moment until its text arrived is the user-visible lag: the decode
  /// itself, plus any backlog when decoding falls behind the speaker. Approximate (it takes the
  /// tap's first buffer as audio time zero and FluidAudio's updates carry no decode time), which is
  /// enough to tell "keeps up" from "falls behind".
  private func recordLag() {
    defer { stats.windows += 1 }
    guard let audioStarted = stats.audioStarted else { return }
    let readyAt =
      Double(stats.windows + 1) * ParakeetLivePreview.hopSeconds + ParakeetLivePreview.rightContextSeconds
    let lagMs = max(0, (Date().timeIntervalSince(audioStarted) - readyAt) * 1000)
    stats.totalLagMs += lagMs
    stats.maxLagMs = max(stats.maxLagMs, lagMs)
  }

  private func fail(stage: String, error: Error, session: UUID) {
    guard self.session == session else { return }
    if error is CancellationError { return }
    stats.errors += 1
    DebugLogger.logWarning(
      "LIVE-PREVIEW: \(stage) failed, preview hidden; dictation continues (\(String(describing: error)))")
    stop()
  }

  private func logSummary(session: UUID) {
    let seconds = Date().timeIntervalSince(stats.started)
    let meanLag = stats.windows > 0 ? stats.totalLagMs / Double(stats.windows) : 0
    DebugLogger.log(
      "LIVE-PREVIEW: summary windows=\(stats.windows) meanLagMs=\(Int(meanLag)) maxLagMs=\(Int(stats.maxLagMs)) "
        + "hopMs=\(Int(ParakeetLivePreview.hopSeconds * 1000)) errors=\(stats.errors) tapRestarts=\(stats.tapRestarts) "
        + "durationS=\(String(format: "%.1f", seconds)) chars=\(confirmed.count + volatile.count)")
  }

  /// The Dictate language the final offline decode uses (`SpeechService`, offline branch): the ISO
  /// code, or nil for auto-detect.
  private static func dictateLanguageCode() -> String? {
    let saved = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage)
    return (WhisperLanguage(rawValue: saved ?? WhisperLanguage.auto.rawValue) ?? .auto).languageCode
  }
}

/// A second, read-only listener on the microphone for the preview. `ChunkedDictateRecorder` keeps
/// recording to files through `AVAudioRecorder` exactly as before; this engine only hands 16 kHz
/// mono buffers to the preview, and is never created while the setting is off.
///
/// `AVAudioEngine.start()` and `stop()` block on CoreAudio like `AVAudioRecorder.record()` does
/// (see the recorder's `audioQueue`), so all engine work runs on a serial queue of its own.
///
/// A device or format change stops an engine silently. Bluetooth headsets cause one right at the
/// start (opening their microphone switches them to the hands-free profile), so the tap is rebuilt
/// once with the new format; only a second change ends the preview.
final class LiveDictateAudioTap {
  enum TapError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    case configurationChangedAgain

    var errorDescription: String? {
      switch self {
      case .noInputDevice: return "No usable input format on the default input device"
      case .converterUnavailable: return "Cannot convert the input format to 16 kHz mono"
      case .configurationChangedAgain: return "The audio input changed again while recording"
      }
    }
  }

  /// Reference boxes, not captured `var`s: the SDK types the tap and converter blocks
  /// `@Sendable`, and mutating a captured var there does not compile. Only the render thread
  /// touches them.
  private final class Flag: @unchecked Sendable {
    var isSet = false
  }

  private struct Handlers {
    let onFirstBuffer: () -> Void
    let onBuffer: (AVAudioPCMBuffer) -> Void
    let onRestart: () -> Void
    let onFailure: (Error) -> Void
  }

  private static let maxRestarts = 1

  private let queue = DispatchQueue(label: "com.whispershortcut.live-dictate-tap", qos: .userInitiated)
  // Everything below is only touched on `queue`.
  private var engine: AVAudioEngine?
  private var configurationObserver: NSObjectProtocol?
  private var handlers: Handlers?
  private var restarts = 0

  /// `onBuffer` runs on the audio render thread. `onFirstBuffer`, `onRestart` and `onFailure` run
  /// on the main thread.
  func start(
    onFirstBuffer: @escaping () -> Void,
    onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
    onRestart: @escaping () -> Void,
    onFailure: @escaping (Error) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.handlers = Handlers(
        onFirstBuffer: onFirstBuffer, onBuffer: onBuffer, onRestart: onRestart, onFailure: onFailure)
      self.restarts = 0
      self.startEngineOnQueue()
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.stopEngineOnQueue()
      self?.handlers = nil
    }
  }

  private func startEngineOnQueue() {
    stopEngineOnQueue()
    guard let handlers else { return }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    // `installTap` raises an Objective-C exception on a zero format (no input device).
    guard format.sampleRate > 0, format.channelCount > 0 else {
      report(TapError.noInputDevice)
      return
    }
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: ParakeetLivePreview.sampleRate, channels: 1,
        interleaved: false),
      let converter = AVAudioConverter(from: format, to: target)
    else {
      report(TapError.converterUnavailable)
      return
    }
    // The first input channel, not a mix of all: on a multi-channel interface the microphone is
    // usually on input 1, and averaging in silent channels would only lower its level.
    converter.channelMap = [0]
    let ratio = target.sampleRate / format.sampleRate
    let firstBuffer = Flag()
    let onBuffer = handlers.onBuffer
    let onFirstBuffer = handlers.onFirstBuffer
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
      guard let converted = Self.convert(buffer, with: converter, to: target, ratio: ratio) else { return }
      if !firstBuffer.isSet {
        firstBuffer.isSet = true
        DispatchQueue.main.async { onFirstBuffer() }
      }
      onBuffer(converted)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      report(error)
      return
    }
    self.engine = engine
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      self?.queue.async { self?.handleConfigurationChange() }
    }
    DebugLogger.logAudio(
      "LIVE-PREVIEW: Audio tap started (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch → 16 kHz mono)")
  }

  private func handleConfigurationChange() {
    guard engine != nil, let handlers else { return }
    guard restarts < Self.maxRestarts else {
      report(TapError.configurationChangedAgain)
      return
    }
    restarts += 1
    DebugLogger.logAudio("LIVE-PREVIEW: Audio input changed; rebuilding the tap with the new format")
    DispatchQueue.main.async { handlers.onRestart() }
    startEngineOnQueue()
  }

  private func stopEngineOnQueue() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    guard let engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
    DebugLogger.logAudio("LIVE-PREVIEW: Audio tap stopped")
  }

  /// Stops the engine and tells the controller. On `queue`.
  private func report(_ error: Error) {
    stopEngineOnQueue()
    guard let onFailure = handlers?.onFailure else { return }
    handlers = nil
    DispatchQueue.main.async { onFailure(error) }
  }

  /// One input buffer through the session's long-lived converter, so the resampler keeps its
  /// state across buffers. The result is a new buffer; the tap's own may be reused by the engine.
  private static func convert(
    _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat, ratio: Double
  ) -> AVAudioPCMBuffer? {
    guard buffer.frameLength > 0 else { return nil }
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    let consumed = Flag()
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if consumed.isSet {
        // `.noDataNow`, not `.endOfStream`: the stream goes on with the next tap buffer.
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed.isSet = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, error == nil, output.frameLength > 0 else { return nil }
    return output
  }
}
