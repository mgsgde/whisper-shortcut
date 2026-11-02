import AVFoundation
import Foundation

/// Runs the live text panel for one Dictate recording (plans/active/live-dictate-preview.md, S2).
///
/// `MenuBarController` calls `startIfEnabled` once capture has begun and `stop` whenever the app
/// leaves Dictate recording — Stop, ✕, Fn-discard, a failed recording. Everything here is a
/// preview and fails closed: any error logs, hides the panel and ends the preview, and nothing it
/// does reaches the dictation. The recorder (`ChunkedDictateRecorder`) and the final transcript
/// path do not know it exists.
///
/// With the setting off, `startIfEnabled` returns at its first line: no model call, no
/// `AVAudioEngine`, no panel.
///
/// Main thread only.
final class LiveDictatePreviewController {
  private let tap = LiveDictateAudioTap()
  private var preview: ParakeetLivePreview?
  private var startTask: Task<Void, Never>?
  /// Identifies the running session; callbacks from an older one are dropped. Nil when idle.
  private var session: UUID?
  private var merger = LiveTranscriptMerger()
  private var stats = Stats()

  /// What the `LIVE-PREVIEW:` summary line reports (plan, Design 6).
  private struct Stats {
    var started = Date()
    /// When the tap delivered its first buffer; window lag is measured from here.
    var audioStarted: Date?
    var windows = 0
    var totalLagMs: Double = 0
    var maxLagMs: Double = 0
    var errors = 0
  }

  /// - Parameters:
  ///   - vocabulary: the Glossary terms the final Parakeet decode boosts (`SpeechService.glossaryKeywords`).
  func startIfEnabled(vocabulary: @autoclosure () -> [String]) {
    guard LiveDictatePreviewSetting.isEnabled else { return }
    stop()
    let model = TranscriptionModel.loadSelected()
    guard
      LiveDictatePreviewSetting.shouldStart(
        enabled: true, model: model, downloaded: model.isOfflineModelAvailable()),
      let modelType = model.offlineModelType
    else {
      DebugLogger.log("LIVE-PREVIEW: Not started — needs a downloaded Parakeet as the Dictate model")
      return
    }

    let session = UUID()
    self.session = session
    merger = LiveTranscriptMerger()
    stats = Stats()
    let language = Self.dictateLanguageCode()
    let terms = vocabulary()
    DebugLogger.log(
      "LIVE-PREVIEW: Starting (language=\(language ?? "auto"), glossaryTerms=\(terms.count), hop=\(ParakeetLivePreview.hopSeconds)s)")

    startTask = Task { [weak self] in
      do {
        let backend = try await LocalSpeechService.shared.parakeetBackendForLivePreview(modelType)
        let preview = try await backend.makeLivePreview(language: language, vocabulary: terms) {
          text, isConfirmed in
          DispatchQueue.main.async { self?.handleWindow(text, isConfirmed: isConfirmed, session: session) }
        }
        let cancelled = Task.isCancelled  // read on this task, not inside MainActor.run
        await MainActor.run {
          guard let self, self.session == session, !cancelled else {
            preview.stop()
            return
          }
          self.preview = preview
          self.startTap(feeding: preview, session: session)
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
  }

  // MARK: - Steps

  private func startTap(feeding preview: ParakeetLivePreview, session: UUID) {
    tap.start(
      onFirstBuffer: { [weak self] in
        guard let self, self.session == session else { return }
        self.stats.audioStarted = Date()
      },
      onBuffer: { buffer in preview.append(buffer) },
      completion: { [weak self] error in
        guard let self, self.session == session else { return }
        if let error {
          self.fail(stage: "audio", error: error, session: session)
          return
        }
        LiveDictatePanel.shared.show()
      })
  }

  private func handleWindow(_ text: String, isConfirmed: Bool, session: UUID) {
    guard self.session == session else { return }
    merger.ingest(text, isConfirmed: isConfirmed)
    recordLag()
    LiveDictatePanel.shared.update(committed: merger.committedText, tentative: merger.tentativeText)
  }

  /// Window `n` (0-based) can be decoded once `(n + 1) × hop + right context` seconds of audio
  /// exist. The time past that moment until its text arrived is the user-visible lag: the decode
  /// itself, plus any backlog when decoding falls behind the speaker. Approximate (it takes the
  /// tap's start as audio time zero), which is enough to tell "keeps up" from "falls behind".
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
        + "hopMs=\(Int(ParakeetLivePreview.hopSeconds * 1000)) errors=\(stats.errors) "
        + "durationS=\(String(format: "%.1f", seconds)) chars=\(merger.committedText.count + merger.tentativeText.count)")
  }

  /// The Dictate language the final offline decode uses (`SpeechService`, offline branch): the ISO
  /// code, or nil for auto-detect.
  private static func dictateLanguageCode() -> String? {
    let saved = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage)
    return (WhisperLanguage(rawValue: saved ?? WhisperLanguage.auto.rawValue) ?? .auto).languageCode
  }
}

/// A second, read-only listener on the microphone for the preview. `ChunkedDictateRecorder` keeps
/// recording to files through `AVAudioRecorder` exactly as before; this engine only copies PCM
/// buffers out for the preview, and is never created while the setting is off.
///
/// `AVAudioEngine.start()` and `stop()` block on CoreAudio like `AVAudioRecorder.record()` does
/// (see the recorder's `audioQueue`), so both run on a serial queue of their own.
final class LiveDictateAudioTap {
  enum TapError: LocalizedError {
    case noInputDevice
    case configurationChanged

    var errorDescription: String? {
      switch self {
      case .noInputDevice: return "No usable input format on the default input device"
      case .configurationChanged: return "The audio input changed while recording"
      }
    }
  }

  private final class FirstBufferFlag: @unchecked Sendable {
    var seen = false
  }

  private let queue = DispatchQueue(label: "com.whispershortcut.live-dictate-tap", qos: .userInitiated)
  /// Only touched on `queue`.
  private var engine: AVAudioEngine?
  private var configurationObserver: NSObjectProtocol?

  /// `onBuffer` runs on the audio render thread with a private copy of each buffer. `completion`
  /// and `onFirstBuffer` run on the main thread; a later device change reports through
  /// `completion` again with `.configurationChanged`.
  func start(
    onFirstBuffer: @escaping () -> Void,
    onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
    completion: @escaping (Error?) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.stopOnQueue()
      let engine = AVAudioEngine()
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      // `installTap` raises an Objective-C exception on a zero format (no input device).
      guard format.sampleRate > 0, format.channelCount > 0 else {
        DispatchQueue.main.async { completion(TapError.noInputDevice) }
        return
      }
      // A box, not a captured `var`: the SDK types the tap block `@Sendable`, and mutating a
      // captured var there does not compile. Only the render thread touches it.
      let firstBuffer = FirstBufferFlag()
      input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let copy = Self.copy(buffer) else { return }
        if !firstBuffer.seen {
          firstBuffer.seen = true
          DispatchQueue.main.async(execute: onFirstBuffer)
        }
        onBuffer(copy)
      }
      engine.prepare()
      do {
        try engine.start()
      } catch {
        input.removeTap(onBus: 0)
        DispatchQueue.main.async { completion(error) }
        return
      }
      self.engine = engine
      // A device switch stops the engine silently; end the preview instead of showing a frozen one.
      self.configurationObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
      ) { _ in completion(TapError.configurationChanged) }
      DebugLogger.logAudio(
        "LIVE-PREVIEW: Audio tap started (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
      DispatchQueue.main.async { completion(nil) }
    }
  }

  func stop() {
    queue.async { [weak self] in self?.stopOnQueue() }
  }

  private func stopOnQueue() {
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

  /// The engine may reuse a tap buffer once the block returns, and the preview reads it later on
  /// another thread, so each one is copied.
  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard buffer.frameLength > 0,
      let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
    else { return nil }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (from, to) in zip(source, destination) {
      guard let fromData = from.mData, let toData = to.mData else { return nil }
      let bytes = min(Int(from.mDataByteSize), Int(to.mDataByteSize))
      memcpy(toData, fromData, bytes)
    }
    return copy
  }
}
