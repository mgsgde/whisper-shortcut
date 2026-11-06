import AppKit
import Foundation
import Network

/// Owns one live-meeting recording session end to end: the transcript file, the chunk pipeline, and
/// the rolling-summary policy.
///
/// All of this used to live as 17 loose `liveMeeting*` properties on `MenuBarController` — a
/// finalization latch, an awaiting-final-chunk gate, a pending-chunk count, a circuit breaker, a
/// single-flight guard, a generation counter, two "already alerted" flags — which every
/// start / stop / resume / discard path had to reset in exactly the right combination.
/// `LiveMeetingRecorder` only ever owned audio rotation, so the *session* had no owner: the state
/// that governs correctness was spread across ~600 lines of a class that also draws menus, plays
/// TTS and drives the clipboard.
///
/// What deliberately stays outside: `appState`. It is the app's single source of truth and remains
/// `MenuBarController`'s to mutate — this type reports the lifecycle through `onFinished` and asks
/// about it through `appStateIsRecordingMeeting`.
///
/// One instance is kept for the app's lifetime and reused across meetings, mirroring how the fields
/// behaved on the controller. In particular `sessionGeneration` still discriminates a straggler
/// summary call from a previous meeting; per-meeting instances would have changed that semantics.
final class LiveMeetingSession: NSObject {

  // MARK: - Collaborators

  /// Transcribes one recorded chunk. Injected so the session doesn't reach into the controller's
  /// `SpeechService`.
  private let transcribeChunk: (URL) async throws -> String
  /// Removes a delivered chunk file.
  private let cleanUpAudioFile: (URL) -> Void
  /// True while `appState` is `.recording(.liveMeeting)`. The session cannot read `appState`
  /// itself — see the note above.
  private let appStateIsRecordingMeeting: () -> Bool
  /// The user asked to stop and the session is now draining the last chunk(s). Reported separately
  /// from `onFinished` because that drain takes a network round trip: without it the owner keeps
  /// showing "recording" for seconds after the stop, which reads as the stop not having worked.
  private let onStopping: () -> Void
  /// The session has fully finished (saved or discarded); the owner returns `appState` to idle.
  private let onFinished: () -> Void
  /// The set of kept, untranscribed meeting audio changed (a chunk was kept, or a retry ran); the
  /// owner refreshes the status menu's retry row.
  private let onBacklogChanged: () -> Void
  /// How long `stop()` waits for the recorder's final chunk before finishing the session anyway.
  private let stopSafetyNetDelay: TimeInterval
  /// Replaces the body of an end-of-meeting pass (consolidation + summary, which call an LLM). Tests
  /// inject one so they neither need a key nor spend a request; production leaves it nil. Pass
  /// scheduling (one in flight per stem, rerun when dirty) stays real.
  private let postProcessingOverride: (@MainActor (URL, [LiveMeetingChunk]) async -> Void)?
  /// The two LLM requests of a pass. Tests inject them so the real pass (epoch gating, rename,
  /// file handling) runs without a key; production leaves it nil and uses the selected models.
  struct PostProcessingCalls {
    var consolidate: (String) async throws -> String
    var summarize: (String) async throws -> String
  }
  private let postProcessingCalls: PostProcessingCalls?
  /// Shows the alert for a chunk that failed after its meeting ended. Tests capture it instead of
  /// opening a window; production leaves it nil.
  private let presentEndedMeetingAlert: ((String) -> Void)?

  init(
    transcribeChunk: @escaping (URL) async throws -> String,
    cleanUpAudioFile: @escaping (URL) -> Void,
    appStateIsRecordingMeeting: @escaping () -> Bool,
    onStopping: @escaping () -> Void,
    onFinished: @escaping () -> Void,
    onBacklogChanged: @escaping () -> Void,
    stopSafetyNetDelay: TimeInterval = 30,
    postProcessingOverride: (@MainActor (URL, [LiveMeetingChunk]) async -> Void)? = nil,
    postProcessingCalls: PostProcessingCalls? = nil,
    presentEndedMeetingAlert: ((String) -> Void)? = nil
  ) {
    self.transcribeChunk = transcribeChunk
    self.cleanUpAudioFile = cleanUpAudioFile
    self.appStateIsRecordingMeeting = appStateIsRecordingMeeting
    self.onStopping = onStopping
    self.onFinished = onFinished
    self.onBacklogChanged = onBacklogChanged
    self.stopSafetyNetDelay = stopSafetyNetDelay
    self.postProcessingOverride = postProcessingOverride
    self.postProcessingCalls = postProcessingCalls
    self.presentEndedMeetingAlert = presentEndedMeetingAlert
    super.init()
    // The meeting bar's preference (automatic / always mix / microphone only) can change mid-meeting.
    audioPreferenceObserver = NotificationCenter.default.addObserver(
      forName: .liveMeetingAudioPreferenceChanged, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, self.recorder != nil, !self.stopping, !self.finalized else { return }
      // A new choice is a new attempt: the tap's last failure was for the previous choice.
      self.systemAudioStartFailed = false
      self.reconcileSystemAudio()
    }
  }

  deinit {
    if let audioPreferenceObserver {
      NotificationCenter.default.removeObserver(audioPreferenceObserver)
    }
  }

  // MARK: - System audio routing

  private var audioPreferenceObserver: NSObjectProtocol?
  private var outputRouteMonitor: OutputRouteMonitor?
  private var systemCapture: SystemAudioCapture?
  /// The tap failed to start during this meeting. Reconcile must not start it again until the
  /// meeting starts over or the user changes the preference.
  private var systemAudioStartFailed = false
  private var didShowSystemAudioAlert = false

  private func startOutputRouteMonitor() {
    outputRouteMonitor?.stop()
    let monitor = OutputRouteMonitor()
    outputRouteMonitor = monitor
    monitor.onChange = { [weak self] route in
      guard let self, self.recorder != nil, !self.stopping, !self.finalized else { return }
      LiveMeetingTranscriptStore.shared.outputRoute = route
      self.reconcileSystemAudio()
    }
    monitor.start()
    LiveMeetingTranscriptStore.shared.outputRoute = monitor.route
    reconcileSystemAudio()
  }

  private func stopOutputRouteMonitor() {
    outputRouteMonitor?.stop()
    outputRouteMonitor = nil
  }

  /// Starts or stops the system-audio tap so it matches the preference and the output route.
  /// A change of either cuts the chunk in progress first, so one file is not mixed two ways.
  private func reconcileSystemAudio() {
    let routing = MeetingAudioRouting.resolve(
      preference: .current, route: outputRouteMonitor?.route)
    if routing.mixesSystemAudio {
      if systemCapture == nil, !systemAudioStartFailed {
        recorder?.rotateNow(minimumChunkAge: 0.5)
        startSystemCapture()
      }
    } else if systemCapture != nil {
      recorder?.rotateNow(minimumChunkAge: 0.5)
      tearDownSystemCapture()
    }
    let systemAudio = systemCapture == nil ? "off" : "on"
    DebugLogger.log("LIVE-MEETING: audio routing \(routing) (system audio \(systemAudio))")
  }

  private func startSystemCapture() {
    let store = LiveMeetingTranscriptStore.shared
    let capture = SystemAudioCapture()
    capture.onPermissionSuspectedChange = { [weak self] suspected in
      DispatchQueue.main.async {
        store.systemAudioSeemsBlocked = suspected
        if suspected { self?.showSystemAudioBlockedAlert() }
      }
    }
    // start() returns at once; the tap comes up off the main thread and a failure arrives via
    // onStartFailed. Never abort the meeting: it keeps recording from the microphone.
    capture.onStartFailed = { [weak self, weak capture] error in
      guard let self, let capture, self.systemCapture === capture else { return }
      DebugLogger.logError("LIVE-MEETING: System audio capture failed to start: \(error)")
      self.systemAudioStartFailed = true
      self.recorder?.systemAudio = nil
      self.systemCapture = nil
      store.isCapturingSystemAudio = false
      store.systemAudioSeemsBlocked = true
      self.showSystemAudioBlockedAlert()
    }
    systemCapture = capture
    recorder?.systemAudio = capture.buffer
    store.isCapturingSystemAudio = true
    capture.start()
  }

  /// Stops the tap and clears the runtime flags. A chunk already cut keeps its own buffer reference.
  private func tearDownSystemCapture() {
    recorder?.systemAudio = nil
    systemCapture?.stop()
    systemCapture = nil
    let store = LiveMeetingTranscriptStore.shared
    store.isCapturingSystemAudio = false
    store.systemAudioSeemsBlocked = false
  }

  private func showSystemAudioBlockedAlert() {
    guard !didShowSystemAudioAlert else { return }
    didShowSystemAudioAlert = true
    PopupNotificationWindow.showError(
      "WhisperShortcut can't hear the other participants. Allow WhisperShortcut under System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording. Until then the meeting is recorded from your microphone only.",
      title: "System Audio Not Recorded",
      retryAction: { PermissionStatusChecker.openSystemSettings(for: .screenRecording) },
      retryActionTitle: "Open System Settings")
  }

  // MARK: - Session state

  private var recorder: LiveMeetingRecorder?
  private var stopping: Bool = false
  /// Latched true once `finish()` has run; used to drop late chunk deliveries from AVAudioRecorder
  /// that arrive after the post-processing Task started.
  private var finalized: Bool = false
  /// Set to true on stop; cleared when the recorder delivers its final chunk. Gates `finish()` so
  /// post-processing can't start before the last audio arrives.
  private var awaitingFinalChunk: Bool = false
  private var transcriptURL: URL?
  private var pendingChunks: Int = 0
  private var safeguardTimer: Timer?
  /// Armed by `stop()`. When it fires for the current meeting it zeroes `pendingChunks` and finishes
  /// the session even if a chunk is still transcribing; that chunk then lands as a late chunk (see
  /// `appendToTranscript`). The handle is kept so tests can fire one left over from an earlier meeting.
  private var stopSafetyNet: DispatchWorkItem?
  /// How a meeting ended, by generation, so a chunk still transcribing afterwards can find the file
  /// it belongs to: renamed by the user at End, or deleted because they discarded. Only recent
  /// generations are kept.
  private enum FinishedMeeting {
    case discarded
    case saved(URL)
  }
  private var finishedMeetings: [Int: FinishedMeeting] = [:]
  /// Generations whose late-failure alert was shown; one per ended meeting, however many chunks fail.
  private var endedMeetingAlertShown: Set<Int> = []
  /// Bumped per transcript stem on every write to its transcript (a chunk, recovered audio). A pass
  /// whose number is no longer current was overtaken: its view of the transcript is stale, so it
  /// stops before the next LLM call and must not overwrite the file, the summary or alert.
  private var postProcessingEpochs: [String: Int] = [:]
  /// Stems with a pass running. At most one per stem, so N late chunks do not start N passes.
  private var postProcessingInFlight: Set<String> = []
  /// Stems that asked for a pass while one was running; one rerun follows it.
  private var postProcessingDirty: [String: URL] = [:]
  /// ID of the last chunk already covered by a live note. Robust against chunk trimming.
  private var lastNotedChunkID: UUID? = nil
  /// When non-nil, `finish()` renames the transcript file to this stem (or timestamp-suffix) before ending.
  private var preferredName: String?
  /// Set to true after showing the rate-limit popup once this session so we don't spam.
  private var didShowRateLimitAlert: Bool = false
  /// Set after the first "this part couldn't be transcribed" popup of a session. One is enough to
  /// tell the user; every further failed chunk is kept the same way.
  private var didShowTranscriptionFailureAlert: Bool = false
  /// True while `retryBacklog` runs, so a second click can't transcribe the same files twice.
  private(set) var isRetryingBacklog: Bool = false
  /// Retry requests that arrived while a pass was running; one more pass handles them.
  private var hasPendingRetry = false
  private var pendingRetryStems: Set<String> = []
  private var pendingRetryAll = false
  private var pendingRetryAnnounce = false
  /// Consecutive live-note failures (e.g. sustained Gemini 503). Reset to 0 on any success.
  private var consecutiveNoteFailures: Int = 0
  /// True once the live-note circuit-breaker has tripped: we stop generating further notes for this
  /// session (the final summary is still attempted at end). Prevents hammering an unavailable model
  /// dozens of times during one meeting.
  private var noteCircuitOpen: Bool = false
  /// Set to true after showing the "live notes unavailable" popup once this session so we don't spam.
  private var didShowNoteFailureAlert: Bool = false
  /// Consecutive live-note failures before the circuit-breaker opens and we notify the user.
  private let noteFailureThreshold = 3
  /// Single-flight guard: true while a live-note API call is in flight. Notes are small (a segment
  /// in, two bullets out) so calls are fast, but a slow response must not let a second call start
  /// and race on `lastNotedChunkID` — that would either duplicate or skip a segment.
  private var noteUpdateInFlight: Bool = false
  /// Bumped on every session start. A Task that can outlive the meeting (live notes, a chunk
  /// transcription, the stop safety net) captures the generation it launched under and leaves the
  /// newer session alone instead of writing into it or finishing it.
  private var sessionGeneration = 0
  /// Minimum new transcript characters before a live note is generated. Below this a segment is
  /// usually a greeting or a stray sentence and produces a note not worth its API call.
  private let liveNoteMinChars = 400
  /// …unless this many chunks have piled up, which happens when people speak in short bursts.
  private let liveNoteMaxPendingChunks = 4
  /// When true, `finish()` deletes the transcript instead of saving.
  private var discard: Bool = false
  /// Callers of `flushPendingAudio()` waiting for the chunk that flush cut to be transcribed, keyed
  /// so a timeout can drop its own waiter without disturbing the others.
  private var flushWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  /// Index of the chunk the pending flush cut; see `signalFlushCompleted`.
  private var flushAwaitedChunkIndex: Int?

  /// True while this session holds a recorder. Combined with `appState` by the owner to decide
  /// whether a meeting is active.
  var isRecording: Bool { recorder != nil }

  #if DEBUG
  /// Chunks whose transcription has not finished.
  var pendingChunkCount: Int { pendingChunks }

  /// The stop safety net `stop()` armed, so a test can fire one from an earlier meeting.
  var stopSafetyNetForTesting: DispatchWorkItem? { stopSafetyNet }
  #endif

  /// True when a meeting is active (recording, or stopping with pending chunks).
  private var isActive: Bool { appStateIsRecordingMeeting() || recorder != nil }

  // MARK: - Lifecycle

  /// Creates the transcript file and starts the recorder. Returns false (after showing an error)
  /// when the transcript file can't be created, so the caller leaves `appState` untouched.
  func start(resuming: Bool) -> Bool {
    DebugLogger.log("LIVE-MEETING: Starting session (resuming=\(resuming))")
    if !resuming { TelemetryService.shared.started(.meeting) }

    // For a fresh meeting, clear any retained state from a previous (finished) meeting
    // so a new stem is generated and the chat sink doesn't reattach to the old session.
    if !resuming {
      LiveMeetingTranscriptStore.shared.clearForNewMeeting()
    }

    // Create transcript file (stem is pre-generated by LiveMeetingTranscriptStore)
    do {
      transcriptURL = try createTranscriptFile()
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to create transcript file: \(error)")
      PopupNotificationWindow.showError(
        "Failed to create transcript file", title: "Live Meeting Error")
      return false
    }

    // Transcript is shown in the app's Meeting view; do not open the .txt file in an external app.

    // Load chunk interval from settings
    let chunkInterval = Self.configuredChunkInterval()

    // Compute resume offset so new chunks continue from where the previous recording
    // left off, keeping transcript timestamps monotonic.
    let existingChunks = LiveMeetingTranscriptStore.shared.chunks
    let resumeOffset: TimeInterval
    if let last = existingChunks.last {
      // Buffer past the last chunk's start so labels don't collide.
      resumeOffset = last.startTime + max(1, chunkInterval)
    } else {
      resumeOffset = 0
    }

    // Create and start recorder
    recorder = LiveMeetingRecorder(maxChunkDuration: chunkInterval)
    recorder?.delegate = self
    recorder?.startSession(resumeTimeOffset: resumeOffset)
    didShowSystemAudioAlert = false
    systemAudioStartFailed = false
    startOutputRouteMonitor()

    // Update state
    stopping = false
    finalized = false
    awaitingFinalChunk = false
    pendingChunks = 0
    didShowRateLimitAlert = false
    didShowTranscriptionFailureAlert = false
    consecutiveNoteFailures = 0
    noteCircuitOpen = false
    didShowNoteFailureAlert = false
    noteUpdateInFlight = false
    sessionGeneration += 1
    if resuming && !existingChunks.isEmpty {
      LiveMeetingTranscriptStore.shared.resumeSession()
      // Everything already on disk has been noted; only new chunks need a note.
      lastNotedChunkID = existingChunks.last?.id
    } else {
      LiveMeetingTranscriptStore.shared.startSession()
      lastNotedChunkID = nil
    }

    // Schedule duration safeguard if enabled
    let safeguardThreshold = MeetingSafeguardDuration.loadFromUserDefaults()
    if safeguardThreshold != .never {
      safeguardTimer?.invalidate()
      safeguardTimer = Timer.scheduledTimer(
        withTimeInterval: safeguardThreshold.rawValue, repeats: false
      ) { [weak self] _ in
        self?.showSafeguardAlert(thresholdMinutes: Int(safeguardThreshold.rawValue / 60))
      }
      if let timer = safeguardTimer {
        RunLoop.main.add(timer, forMode: .common)
      }
      DebugLogger.log(
        "LIVE-MEETING-SAFEGUARD: Reminder scheduled after \(Int(safeguardThreshold.rawValue / 60)) minutes"
      )
    }

    warnIfTranscriptionUnreachable()

    if let url = transcriptURL {
      LiveMeetingRecordingMarker.write(stem: url.deletingPathExtension().lastPathComponent)
    }

    DebugLogger.logSuccess("LIVE-MEETING: Session started")
    return true
  }

  #if DEBUG
  /// Points the session at `url` and bumps the generation, without opening a microphone.
  /// Tests deliver chunks through the recorder delegate; production goes through `start()`.
  func beginSessionWithoutRecorder(transcriptFile url: URL) {
    transcriptURL = url
    LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem =
      url.deletingPathExtension().lastPathComponent
    stopping = false
    finalized = false
    awaitingFinalChunk = false
    pendingChunks = 0
    discard = false
    preferredName = nil
    sessionGeneration += 1
  }
  #endif

  /// Records the user's meeting name / discard choice, then stops. Posted by the in-window
  /// "end meeting" affordance. The name and discard are stored before `stop()`, so a second
  /// press still updates them when `stop()` itself no-ops.
  func end(preferredName name: String?, discard shouldDiscard: Bool) {
    preferredName = name
    discard = shouldDiscard
    stop()
  }

  /// Called when the app is about to exit while a meeting is recording (system quit, update
  /// script, logout). Keeps the chunk in progress in the audio backlog so it is transcribed when the
  /// meeting is resumed or ended, instead of vanishing with the process. The recording marker is
  /// left in place on purpose: the next launch reads it to resume or report the interruption.
  func preserveForTermination() {
    guard let recorder, !stopping, !finalized else { return }
    let stem = transcriptURL?.deletingPathExtension().lastPathComponent
    let chunk = recorder.stopForTermination()
    stopOutputRouteMonitor()
    tearDownSystemCapture()
    self.recorder = nil
    guard let chunk else {
      DebugLogger.log("LIVE-MEETING: Terminating mid-meeting, no chunk worth keeping")
      return
    }
    guard let stem else {
      DebugLogger.logWarning("LIVE-MEETING: Terminating mid-meeting, no stem known; chunk left at \(chunk.url.lastPathComponent)")
      return
    }
    let kept = MeetingAudioBacklog.retain(chunk.url, stem: stem, startTime: chunk.startTime)
    DebugLogger.log("LIVE-MEETING: Terminating mid-meeting, in-progress chunk kept in backlog: \(kept)")
  }

  func stop() {
    // A second Stop while the final chunk is still draining re-arms the recorder. No second
    // finish callback arrives, so the meeting sits until the safety net. The name and discard
    // choice are applied by `end()` before this returns.
    guard !stopping else {
      DebugLogger.log("LIVE-MEETING: Stop ignored (already stopping)")
      return
    }
    DebugLogger.log("LIVE-MEETING: User requested stop")
    LiveMeetingRecordingMarker.clear()

    safeguardTimer?.invalidate()
    safeguardTimer = nil
    stopping = true
    // Tell the UI *now*: the drain below needs a transcription round trip, and until it lands both
    // the menu bar and the meeting bar would otherwise keep claiming the meeting is recording.
    LiveMeetingTranscriptStore.shared.beginFinishing()
    onStopping()
    // AVAudioRecorder delivers its final chunk async via audioRecorderDidFinishRecording,
    // so wait for it before finalizing (prevents a race where post-processing rewrites
    // the transcript file while a late chunk is still being appended).
    awaitingFinalChunk = true
    recorder?.stopSession()
    stopOutputRouteMonitor()
    tearDownSystemCapture()

    // Safety net: if the final chunk never arrives, finish anyway so the UI doesn't stay on
    // "stopping". Tied to this generation — a later meeting must not be finished by it.
    let generation = sessionGeneration
    let work = DispatchWorkItem { [weak self] in
      guard let self, generation == self.sessionGeneration else { return }
      guard self.stopping, !self.finalized else { return }
      DebugLogger.logWarning("LIVE-MEETING: Final chunk timeout; finishing session anyway")
      self.awaitingFinalChunk = false
      self.pendingChunks = 0
      self.finish()
    }
    stopSafetyNet = work
    DispatchQueue.main.asyncAfter(deadline: .now() + stopSafetyNetDelay, execute: work)
  }

  private func showSafeguardAlert(thresholdMinutes: Int) {
    safeguardTimer?.invalidate()
    safeguardTimer = nil

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if !self.isActive {
        return
      }
      DebugLogger.log(
        "LIVE-MEETING-SAFEGUARD: Showing duration prompt after \(thresholdMinutes) minutes")
      let alert = NSAlert()
      alert.messageText = String(localized: "Long meeting")
      alert.informativeText = String(
        localized: "This meeting has been transcribing for over \(thresholdMinutes) minutes. Stop or continue?")
      alert.alertStyle = .informational
      alert.addButton(withTitle: String(localized: "Stop meeting"))
      alert.addButton(withTitle: String(localized: "Continue"))
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        DebugLogger.log("LIVE-MEETING-SAFEGUARD: User chose to stop meeting")
        self.stop()
      } else {
        DebugLogger.log("LIVE-MEETING-SAFEGUARD: User chose to continue")
      }
    }
  }

  private func finish() {
    guard !finalized else {
      DebugLogger.log("LIVE-MEETING: finish ignored (already finalized)")
      return
    }
    finalized = true
    LiveMeetingRecordingMarker.clear()
    #if !APP_STORE && canImport(Sparkle)
    Task { @MainActor in UpdaterService.shared.showDeferredUpdateIfAny() }
    #endif

    let shouldDiscard = discard
    DebugLogger.log("LIVE-MEETING: Session finished (discard=\(shouldDiscard))")

    if shouldDiscard {
      if let url = transcriptURL {
        // A summary pass still running for this meeting (it ended, was resumed, now discarded)
        // must not write the transcript back.
        noteTranscriptWrite(stem: url.deletingPathExtension().lastPathComponent)
        try? FileManager.default.removeItem(at: url)
        let summaryURL = url.deletingPathExtension().appendingPathExtension("summary.md")
        try? FileManager.default.removeItem(at: summaryURL)
        try? FileManager.default.removeItem(at: MeetingListService.notesURL(transcriptFileURL: url))
        MeetingAudioBacklog.remove(stem: url.deletingPathExtension().lastPathComponent)
        DebugLogger.log("LIVE-MEETING: Discarded transcript, notes, summary and kept audio")
      }
      transcriptURL = nil
      LiveMeetingTranscriptStore.shared.clearForNewMeeting()
      MeetingListService.shared.refresh()
    } else {
      if let url = transcriptURL, let preferred = preferredName, !preferred.isEmpty {
        let currentStem = url.deletingPathExtension().lastPathComponent
        if preferred != currentStem {
          renameTranscriptFile(from: url, preferredName: preferred, currentStem: currentStem)
        }
      }
      LiveMeetingTranscriptStore.shared.endSession()
    }

    // Capture URL for the post-processing Task before we clear it.
    let transcriptURLForPostProcessing: URL? = shouldDiscard ? nil : transcriptURL

    // A chunk still transcribing finds its way home through this: the renamed file, or nowhere.
    if shouldDiscard {
      finishedMeetings[sessionGeneration] = .discarded
    } else if let url = transcriptURL {
      finishedMeetings[sessionGeneration] = .saved(url)
    }
    finishedMeetings = finishedMeetings.filter { $0.key > sessionGeneration - 16 }
    endedMeetingAlertShown = endedMeetingAlertShown.filter { $0 > sessionGeneration - 16 }

    preferredName = nil
    safeguardTimer?.invalidate()
    safeguardTimer = nil
    stopping = false
    awaitingFinalChunk = false
    discard = false
    stopOutputRouteMonitor()
    tearDownSystemCapture()
    recorder = nil
    pendingChunks = 0
    transcriptURL = nil
    lastNotedChunkID = nil
    // The meeting is over, so nothing further will arrive for a waiter to wait on.
    signalFlushCompleted(completedChunkIndex: nil)
    onFinished()

    if let transcriptURL = transcriptURLForPostProcessing {
      let stem = transcriptURL.deletingPathExtension().lastPathComponent
      if MeetingAudioBacklog.items(stem: stem).isEmpty {
        runPostProcessing(
          transcriptURL: transcriptURL,
          chunks: LiveMeetingTranscriptStore.shared.chunks)
      } else {
        // Some audio failed during the meeting (typically: no connection). The network may well be
        // back by now, so try once more right away; the summary waits until the transcript is whole,
        // otherwise it would summarise the fragment and then fail a second time offline.
        Task { @MainActor in await self.retryBacklog(stems: [stem], announce: false) }
      }
    }

    DebugLogger.logSuccess("LIVE-MEETING: Session cleanup complete")
  }

  /// End-of-meeting pass: consolidate speaker labels across the full transcript, then generate the
  /// final summary from it. Runs detached from the session's own state — everything it needs was
  /// captured before `finish()` cleared the fields.
  /// True only when `consolidated` is non-empty and carries exactly the same sequence of "[m:ss]"
  /// timestamps as `original` (same count, same order). Guards the transcript file against an LLM
  /// that dropped, merged or reordered blocks.
  nonisolated static func acceptsConsolidation(original: String, consolidated: String) -> Bool {
    guard !consolidated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return timestampSequence(original) == timestampSequence(consolidated)
  }

  nonisolated private static func timestampSequence(_ text: String) -> [String] {
    guard let regex = try? NSRegularExpression(
      pattern: #"^\[(\d+):(\d{2})\]"#, options: [.anchorsMatchLines])
    else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
      ns.substring(with: $0.range)
    }
  }

  /// Epoch a pass for `stem` would start under; see `postProcessingEpochs`.
  private func postProcessingEpoch(for stem: String) -> Int { postProcessingEpochs[stem] ?? 0 }

  /// The transcript for `stem` just changed on disk.
  private func noteTranscriptWrite(stem: String) {
    postProcessingEpochs[stem, default: 0] += 1
  }

  /// Rewrites the transcript with consolidated speaker labels unless a newer write overtook this
  /// pass. Runs on the main actor, where every other transcript write happens, so the check and the
  /// write cannot interleave with a late chunk.
  private func writeConsolidatedTranscript(
    _ text: String, to url: URL, stem: String, epoch: Int
  ) throws -> Bool {
    guard postProcessingEpoch(for: stem) == epoch,
      FileManager.default.fileExists(atPath: url.path)
    else { return false }
    try text.write(to: url, atomically: true, encoding: .utf8)
    MeetingListService.shared.invalidateCache(for: nil)
    return true
  }

  /// Starts an end-of-meeting pass for the transcript, or queues one when a pass for the same
  /// meeting is already running (it then reruns once, reading the file as it is by then).
  private func runPostProcessing(
    transcriptURL: URL, chunks chunksSnapshot: [LiveMeetingChunk]
  ) {
    let stem = transcriptURL.deletingPathExtension().lastPathComponent
    guard !postProcessingInFlight.contains(stem) else {
      postProcessingDirty[stem] = transcriptURL
      return
    }
    postProcessingInFlight.insert(stem)
    let epoch = postProcessingEpoch(for: stem)
    Task {
      if let postProcessingOverride {
        await postProcessingOverride(transcriptURL, chunksSnapshot)
      } else {
        await performPostProcessing(
          transcriptURL: transcriptURL, chunks: chunksSnapshot, stem: stem, epoch: epoch)
      }
      await MainActor.run {
        self.postProcessingInFlight.remove(stem)
        if let url = self.postProcessingDirty.removeValue(forKey: stem) {
          self.runPostProcessing(transcriptURL: url, chunks: [])
        }
      }
    }
  }

  private func performPostProcessing(
    transcriptURL: URL, chunks chunksSnapshot: [LiveMeetingChunk], stem: String, epoch: Int
  ) async {
    // Overtaken by a newer write, or the meeting was discarded, renamed or deleted meanwhile.
    func isCurrent() async -> Bool {
      await MainActor.run {
        self.postProcessingEpoch(for: stem) == epoch
          && FileManager.default.fileExists(atPath: transcriptURL.path)
      }
    }
    let injected = postProcessingCalls != nil
    func superseded() {
      DebugLogger.log("LIVE-MEETING: Post-processing superseded by a transcript change; a newer pass follows")
    }
    // Build the input from the file on disk: the in-memory store keeps only the newest chunks,
    // so a long meeting would otherwise be summarised (and overwritten) as a fragment.
    var sourceChunks = chunksSnapshot
    if let fileText = try? String(contentsOf: transcriptURL, encoding: .utf8) {
      let parsed = LiveMeetingTranscriptStore.parseTranscript(fileText)
      if !parsed.isEmpty { sourceChunks = parsed }
    }
    let transcriptText = sourceChunks.map { "\($0.timestampString) \($0.text)" }.joined(
      separator: "\n\n")
    guard !transcriptText.isEmpty else { return }
    let model = PromptModel.loadSelectedMeetingSummary()
    guard injected || model.hasRequiredCredential else {
      DebugLogger.logWarning(
        "LIVE-MEETING: No credential for \(model.rawValue) — skipping post-processing")
      return
    }

    // Skip consolidation when the transcript has at most one distinct speaker — there is nothing
    // to reconcile, and the pass echoes the whole transcript back as (paid) output. When it runs,
    // route to the provider's cheapest model: relabeling is mechanical and doesn't need the
    // summary model's quality.
    var finalTranscript = transcriptText
    let calls = postProcessingCalls ?? PostProcessingCalls(
      consolidate: {
        try await MeetingListService.consolidateSpeakerLabels(
          transcript: $0, model: model.speakerConsolidationModel)
      },
      summarize: { try await MeetingListService.generateSummaryText(transcript: $0, model: model) })
    if !injected, MeetingListService.skipsSpeakerConsolidation(provider: model.provider) {
      DebugLogger.log(
        "LIVE-MEETING: Skipping speaker consolidation (on-device summary model \(model.rawValue))")
    } else if MeetingListService.distinctSpeakerCount(in: transcriptText) >= 2 {
      guard await isCurrent() else { return superseded() }
      do {
        let consolidated = try await calls.consolidate(transcriptText)
        let trimmed = consolidated.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.acceptsConsolidation(original: transcriptText, consolidated: trimmed) {
          DebugLogger.logWarning(
            "LIVE-MEETING: Speaker consolidation rejected (timestamps differ or empty) — keeping original transcript")
        } else {
          finalTranscript = trimmed
          let wrote = try await MainActor.run {
            try self.writeConsolidatedTranscript(trimmed, to: transcriptURL, stem: stem, epoch: epoch)
          }
          guard wrote else { return superseded() }
          DebugLogger.log("LIVE-MEETING: Speaker labels consolidated and transcript rewritten")
        }
      } catch {
        DebugLogger.logWarning(
          "LIVE-MEETING: Speaker consolidation failed (using raw transcript): \(error.localizedDescription)"
        )
      }
    } else {
      DebugLogger.log("LIVE-MEETING: Skipping speaker consolidation (<2 distinct speakers)")
    }

    // Generate summary from the (possibly consolidated) transcript
    guard await isCurrent() else { return superseded() }
    var textForSummary = finalTranscript
    if textForSummary.count > MeetingListService.meetingContextMaxChars {
      textForSummary = String(textForSummary.suffix(MeetingListService.meetingContextMaxChars))
    }
    do {
      let summary = try await calls.summarize(textForSummary)
      let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
      guard await isCurrent() else { return superseded() }
      if !trimmed.isEmpty {
        MeetingListService.shared.saveSummary(trimmed, transcriptFileURL: transcriptURL)
        DebugLogger.log("LIVE-MEETING: Summary saved to .summary.md")
        // Push the fresh summary to the chat sidebar so it can derive a meeting title live
        // (ChatView subscribes to .chatMeetingSummaryReady; without this it relies on the
        // slower backfill recovery path).
        await MainActor.run {
          NotificationCenter.default.post(
            name: .chatMeetingSummaryReady, object: nil,
            userInfo: ["stem": stem, "summary": trimmed])
        }
      }
    } catch {
      DebugLogger.logError("LIVE-MEETING: Generate summary failed: \(error.logDescription)")
      // An overtaken pass fails for a transcript that is about to be summarised again.
      guard await isCurrent() else { return superseded() }
      // Don't lose the summary silently: the transcript is saved, so tell the user it can be
      // regenerated from the meeting library (the recovery path handles a transient outage).
      let offline = OfflineMode.isEnabled
      await MainActor.run {
        PopupNotificationWindow.showError(
          verbatim: offline
            ? String(localized: "The meeting transcript was saved, but the summary couldn't be generated because no on-device summary model is available. Pick one in Settings → Meetings → Meeting Summary Model; you can then regenerate the summary from the meeting library.")
            : String(localized: "The meeting transcript was saved, but the summary couldn't be generated (the summary model is unavailable). You can regenerate it from the meeting library when the service is back."),
          title: "Live Meeting – Summary Failed"
        )
      }
    }
  }

  // MARK: - Untranscribed audio

  static func chunkFailureMessage(error: Error, kept: Bool) -> String {
    let reason = SpeechErrorFormatter.formatForUser(error)
    guard kept else {
      return String(localized: "Part of this meeting couldn't be transcribed: \(reason)")
    }
    return String(localized: "Part of this meeting couldn't be transcribed: \(reason)\n\nRecording continues and the audio is kept on this Mac. It is transcribed again when the meeting ends, or choose Retry Meeting Transcription in the menu bar menu.")
  }

  static func endedMeetingFailureMessage(error: Error) -> String {
    let reason = SpeechErrorFormatter.formatForUser(error)
    return String(localized: "Part of a meeting that has already ended couldn't be transcribed: \(reason)\n\nThe audio is kept on this Mac. Choose Retry Meeting Transcription in the menu bar menu to transcribe it.")
  }

  private func showEndedMeetingAlert(_ message: String) {
    if let presentEndedMeetingAlert {
      presentEndedMeetingAlert(message)
    } else {
      PopupNotificationWindow.showError(verbatim: message, title: "Live Meeting – Transcription Failed")
    }
  }

  /// Warns the moment a meeting starts without a network path, instead of a chunk interval later.
  /// An on-device transcription model needs no network, so it is never warned about.
  private func warnIfTranscriptionUnreachable() {
    guard !TranscriptionModel.loadSelectedForMeeting().isOffline else { return }
    let monitor = NWPathMonitor()
    let generation = sessionGeneration
    var answered = false
    monitor.pathUpdateHandler = { [weak self] path in
      monitor.cancel()
      let isOnline = path.status == .satisfied
      DispatchQueue.main.async {
        guard !answered else { return }
        answered = true
        guard let self, !isOnline, generation == self.sessionGeneration,
          self.appStateIsRecordingMeeting(), !self.didShowTranscriptionFailureAlert
        else { return }
        self.didShowTranscriptionFailureAlert = true
        DebugLogger.logWarning("LIVE-MEETING: Started without a network connection")
        PopupNotificationWindow.showError(
          "There is no internet connection, so this meeting can't be transcribed right now.\n\nRecording continues and the audio is kept on this Mac. It is transcribed when the meeting ends, or choose Retry Meeting Transcription in the menu bar menu once you're back online.",
          title: "Live Meeting – Offline"
        )
      }
    }
    monitor.start(queue: .global(qos: .utility))
  }

  /// Transcribes kept meeting audio again and splices the text into each meeting's transcript at
  /// its original timestamp. A meeting that is recording right now is skipped — its own `finish()`
  /// retries it. Stops at the first real failure: when the network is down every further call
  /// fails the same way, and the files stay for the next attempt.
  ///
  /// `announce` is true for a retry the user asked for, which then also reports success; the
  /// automatic retry at meeting end only speaks up when something is still missing.
  @MainActor
  func retryBacklog(stems: [String]? = nil, announce: Bool) async {
    guard !isRetryingBacklog else {
      // Remember the request (ending meeting B while A's retry runs) and run it after this pass.
      hasPendingRetry = true
      if let stems { pendingRetryStems.formUnion(stems) } else { pendingRetryAll = true }
      pendingRetryAnnounce = pendingRetryAnnounce || announce
      DebugLogger.log("MEETING-BACKLOG: Retry already running, queued another pass")
      return
    }
    isRetryingBacklog = true
    onBacklogChanged()
    await retryBacklogPass(stems: stems, announce: announce)
    while hasPendingRetry {
      let nextStems: [String]? = pendingRetryAll ? nil : Array(pendingRetryStems)
      let nextAnnounce = pendingRetryAnnounce
      hasPendingRetry = false
      pendingRetryAll = false
      pendingRetryStems = []
      pendingRetryAnnounce = false
      await retryBacklogPass(stems: nextStems, announce: nextAnnounce)
    }
    isRetryingBacklog = false
    onBacklogChanged()
  }

  @MainActor
  private func retryBacklogPass(stems: [String]?, announce: Bool) async {
    let activeStem = recorder != nil ? transcriptURL?.deletingPathExtension().lastPathComponent : nil
    let targets = (stems ?? MeetingAudioBacklog.stemsWithBacklog()).filter { $0 != activeStem }
    DebugLogger.log("MEETING-BACKLOG: Retrying \(targets.count) meeting(s)")

    var recovered = 0
    var failure: Error?
    for stem in targets {
      let result = await retryBacklog(stem: stem)
      recovered += result.recovered
      if let error = result.error {
        failure = error
        break
      }
    }
    let remaining = targets.reduce(0) { $0 + MeetingAudioBacklog.items(stem: $1).count }
    onBacklogChanged()
    DebugLogger.log("MEETING-BACKLOG: Retry done (recovered \(recovered), remaining \(remaining))")

    if remaining > 0 {
      let reason = failure.map { SpeechErrorFormatter.formatForUser($0) } ?? String(localized: "The transcription failed.")
      let parts = remaining == 1 ? String(localized: "1 part") : String(localized: "\(remaining) parts")
      PopupNotificationWindow.showError(
        "\(parts) of the meeting couldn't be transcribed yet: \(reason)\n\nThe audio is kept on this Mac. Retry once you're back online — here, or with Retry Meeting Transcription in the menu bar menu.",
        title: "Live Meeting – Transcription Incomplete",
        retryAction: { [weak self] in
          Task { @MainActor in await self?.retryBacklog(stems: targets, announce: true) }
        },
        retryActionTitle: "Retry Now"
      )
    } else if announce {
      PopupNotificationWindow.showInfo(
        verbatim: recovered == 0
          ? String(localized: "The kept meeting audio contained no speech.")
          : String(localized: "The meeting transcript is complete again. The summary is being regenerated."),
        title: "Meeting Transcription Recovered")
    }
  }

  /// One meeting's share of `retryBacklog`. The transcript is rewritten before any audio is
  /// deleted, so a failed write never costs audio.
  @MainActor
  private func retryBacklog(stem: String) async -> (recovered: Int, error: Error?) {
    let transcriptURL = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
      .appendingPathComponent("\(stem).txt")
    var recoveredChunks: [LiveMeetingChunk] = []
    var consumed: [URL] = []
    var failure: Error?
    for item in MeetingAudioBacklog.items(stem: stem) {
      do {
        let text = try await transcribeChunk(item.url)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          recoveredChunks.append(LiveMeetingChunk(startTime: item.startTime, text: text))
        }
        consumed.append(item.url)
      } catch TranscriptionError.noSpeechDetected {
        consumed.append(item.url)
      } catch let error as TranscriptionError where error == .promptLeakDetected || error == .fileTooLarge {
        // Breaking here would block every later chunk and meeting. The audio stays in the backlog:
        // a prompt leak is model output and may pass on a later retry.
        DebugLogger.logWarning("MEETING-BACKLOG: Skipping chunk \(item.url.lastPathComponent) for now: \(error)")
      } catch {
        DebugLogger.logError("MEETING-BACKLOG: Retry failed for \(item.url.lastPathComponent): \(error)")
        failure = error
        break
      }
    }

    let store = LiveMeetingTranscriptStore.shared
    let isShownMeeting = store.currentMeetingFilenameStem == stem
    var merged: [LiveMeetingChunk] = []
    if !recoveredChunks.isEmpty {
      let existingText = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
      merged = MeetingAudioBacklog.merge(
        recoveredChunks, into: LiveMeetingTranscriptStore.parseTranscript(existingText))
      do {
        try FileManager.default.createDirectory(
          at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MeetingAudioBacklog.transcriptText(merged).write(
          to: transcriptURL, atomically: true, encoding: .utf8)
      } catch {
        DebugLogger.logError("MEETING-BACKLOG: Failed to write transcript for \(stem): \(error)")
        return (0, error)
      }
      // A pass already running for this meeting started without these chunks and the audio is
      // about to be deleted, so it must not rewrite the transcript or summary from its older view.
      noteTranscriptWrite(stem: stem)
      if isShownMeeting { store.replaceChunks(merged) }
      MeetingListService.shared.invalidateCache(for: nil)
      MeetingListService.shared.refresh()
      DebugLogger.log("MEETING-BACKLOG: Spliced \(recoveredChunks.count) chunk(s) into \(stem)")
    }
    consumed.forEach { try? FileManager.default.removeItem(at: $0) }
    MeetingAudioBacklog.removeIfEmpty(stem: stem)

    // The summary is only worth writing once the transcript is whole (see `finish()`).
    if failure == nil {
      if merged.isEmpty {
        let text = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        merged = LiveMeetingTranscriptStore.parseTranscript(text)
      }
      if !merged.isEmpty {
        runPostProcessing(
          transcriptURL: transcriptURL, chunks: merged)
      }
    }
    return (recoveredChunks.count, failure)
  }

  // MARK: - Transcript file

  /// Renames the transcript file to include the user's preferred name. Keeps timestamp prefix for parsing.
  private func renameTranscriptFile(from url: URL, preferredName: String, currentStem: String) {
    let timestampPrefix = "Meeting-"
    guard currentStem.hasPrefix(timestampPrefix) else { return }
    let sanitized = preferredName
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sanitized.isEmpty else { return }
    let newStem = "\(currentStem)-\(sanitized)"
    let dir = url.deletingLastPathComponent()
    let newURL = dir.appendingPathComponent("\(newStem).txt")
    // A pass still running under the old name would write its copy back to the old file.
    noteTranscriptWrite(stem: currentStem)
    do {
      if FileManager.default.fileExists(atPath: newURL.path) {
        try FileManager.default.removeItem(at: newURL)
      }
      try FileManager.default.moveItem(at: url, to: newURL)
      // The live notes were written under the old stem while the meeting ran; without moving them
      // too, naming a meeting on the way out would orphan every note it collected.
      let oldNotes = MeetingListService.notesURL(transcriptFileURL: url)
      let newNotes = MeetingListService.notesURL(transcriptFileURL: newURL)
      if FileManager.default.fileExists(atPath: oldNotes.path) {
        try? FileManager.default.removeItem(at: newNotes)
        try? FileManager.default.moveItem(at: oldNotes, to: newNotes)
      }
      MeetingAudioBacklog.rename(stem: currentStem, to: newStem)
      transcriptURL = newURL
      MeetingListService.shared.invalidateCache(for: nil)
      DispatchQueue.main.async {
        LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem = newStem
        LiveMeetingTranscriptStore.shared.preferredMeetingName = sanitized
      }
      DebugLogger.log("LIVE-MEETING: Renamed transcript to \(newStem).txt")
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to rename transcript: \(error.logDescription)")
    }
  }

  private func createTranscriptFile() throws -> URL {
    let meetingsDir = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)

    if !FileManager.default.fileExists(atPath: meetingsDir.path) {
      try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
    }

    // If the store has no stem yet (e.g. first-ever meeting via global shortcut),
    // generate one and publish it so subsequent reads pick the SAME stem.
    let stem: String
    if let existing = LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem {
      stem = existing
    } else {
      stem = LiveMeetingTranscriptStore.generateStem()
      LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem = stem
    }
    let filename = "\(stem).txt"

    let fileURL = meetingsDir.appendingPathComponent(filename)

    // Only create (and thereby truncate) when no file exists yet. On resume the stem is
    // unchanged, so an unconditional createFile(contents: nil) would WIPE the existing
    // transcript; keeping the file lets appendToTranscript continue after the old content.
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      FileManager.default.createFile(atPath: fileURL.path, contents: nil)
      DebugLogger.log("LIVE-MEETING: Created transcript file at \(fileURL.path)")
    } else {
      DebugLogger.log("LIVE-MEETING: Reusing existing transcript file at \(fileURL.path)")
    }
    return fileURL
  }

  /// Where a chunk recorded in `generation` belongs now, or nil when it belongs nowhere.
  ///
  /// A transcription can outlive its meeting: the stop safety net fires at 30s, a request may take
  /// 60s plus retries. By then the user may have discarded the meeting (its file is gone and must
  /// stay gone) or named it (the file moved, so the URL captured at delivery points at nothing).
  /// `finished` is true once the meeting has ended, so the late text needs its summary redone.
  /// Also nil when the transcript is gone: a meeting that was resumed and then discarded, or deleted
  /// from the library, still has an earlier generation recorded as saved.
  private func destination(
    forChunkOf generation: Int, capturedURL: URL?
  ) -> (url: URL, finished: Bool)? {
    let found: (url: URL, finished: Bool)
    switch finishedMeetings[generation] {
    case .discarded:
      return nil
    case .saved(let url):
      found = (url, true)
    case nil:
      guard let capturedURL else { return nil }
      found = (capturedURL, false)
    }
    return FileManager.default.fileExists(atPath: found.url.path) ? found : nil
  }

  /// True while `generation` is the meeting being recorded: it is the newest one and has not ended.
  /// `sessionGeneration` alone only changes at the next `start()`, so a meeting finished by the
  /// stop safety net would still look current.
  private func isLive(_ generation: Int) -> Bool {
    generation == sessionGeneration && finishedMeetings[generation] == nil
  }

  /// Writes `text` into its meeting's transcript at `chunkStartTime`'s place in speaking order.
  ///
  /// `url` and `generation` are the meeting the chunk was recorded for. The text goes to that
  /// meeting's file as it is now (see `destination`) and never creates one: a file that is no longer
  /// there was deleted on purpose. The in-memory store follows the file, so a chunk for the meeting
  /// the store shows (also a resumed one) appears in it, and a chunk for an older meeting does not
  /// show up in the next one.
  private func appendToTranscript(
    _ text: String, chunkStartTime: TimeInterval, url: URL?, generation: Int
  ) {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return }
    // Nil when the meeting was discarded or its transcript is gone (also deleted or renamed from
    // the library); either way the text has nowhere to go and must not recreate a file.
    guard let target = destination(forChunkOf: generation, capturedURL: url) else {
      DebugLogger.log("LIVE-MEETING: Dropping chunk (its meeting was discarded or its transcript is gone)")
      return
    }
    let fileURL = target.url

    let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    let merged = MeetingAudioBacklog.merge(
      [LiveMeetingChunk(startTime: chunkStartTime, text: trimmedText)],
      into: LiveMeetingTranscriptStore.parseTranscript(existing))
    do {
      try MeetingAudioBacklog.transcriptText(merged).write(
        to: fileURL, atomically: true, encoding: .utf8)
      DebugLogger.log(
        "LIVE-MEETING: Wrote chunk to transcript at \(Self.formatTimestamp(elapsedSeconds: chunkStartTime))"
      )
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to write transcript: \(error)")
      return
    }

    let stem = fileURL.deletingPathExtension().lastPathComponent
    // Any pass already running for this meeting started without this text.
    noteTranscriptWrite(stem: stem)
    let store = LiveMeetingTranscriptStore.shared
    if store.currentMeetingFilenameStem == stem {
      store.appendChunk(startTime: chunkStartTime, text: trimmedText)
    }

    if generation == sessionGeneration && !target.finished {
      // Notes run on the next turn so they see the chunk just inserted.
      DispatchQueue.main.async { [weak self] in self?.refreshLiveNotes() }
    } else if target.finished {
      lateChunkLanded(in: fileURL, merged: merged)
    }
  }

  /// A chunk reached a meeting that had already ended. The library list and any summary were built
  /// without it, so refresh the first and redo the second. A meeting resumed into the same file
  /// will summarise when it ends, and one with audio still waiting for a retry summarises after it.
  private func lateChunkLanded(in fileURL: URL, merged: [LiveMeetingChunk]) {
    MeetingListService.shared.invalidateCache(for: nil)
    MeetingListService.shared.refresh()
    let stem = fileURL.deletingPathExtension().lastPathComponent
    let resumedHere = !finalized && transcriptURL?.deletingPathExtension().lastPathComponent == stem
    guard !resumedHere, MeetingAudioBacklog.items(stem: stem).isEmpty else { return }
    DebugLogger.log("LIVE-MEETING: Late chunk landed after the meeting ended; redoing its summary")
    runPostProcessing(transcriptURL: fileURL, chunks: merged)
  }

  static func formatTimestamp(elapsedSeconds: TimeInterval) -> String {
    let minutes = Int(elapsedSeconds) / 60
    let seconds = Int(elapsedSeconds) % 60
    return String(format: "[%02d:%02d]", minutes, seconds)
  }

  // MARK: - Live notes

  /// Generates the next live note when enough new transcript has accumulated.
  ///
  /// Called after every transcript append — the note stream is what the user reads during the
  /// meeting, so it must keep up on its own rather than waiting for someone to open a tab. Pass
  /// `force: true` to note whatever is pending right now (used when the user asks the chat a
  /// question, so their turn sees a current note stream).
  func refreshLiveNotes(force: Bool = false) {
    // Only meaningful while a meeting is actively recording (the live store owns the current stem).
    guard appStateIsRecordingMeeting() else { return }

    // Circuit-breaker: after repeated failures (e.g. a sustained model outage) we stop generating
    // notes for the rest of the session instead of retrying for an hour. The end-of-meeting summary
    // is still attempted once in finish().
    guard !noteCircuitOpen else { return }

    // Single-flight: a second concurrent call would race on `lastNotedChunkID` and either duplicate
    // or skip a segment. Whatever is pending is picked up by the next append.
    guard !noteUpdateInFlight else { return }

    let store = LiveMeetingTranscriptStore.shared
    let pending = store.chunks(afterID: lastNotedChunkID)
    guard let newLastID = pending.last?.id, let firstStart = pending.first?.startTime else { return }

    let segment = pending.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n")
    guard !segment.isEmpty else { return }
    if !force && segment.count < liveNoteMinChars && pending.count < liveNoteMaxPendingChunks {
      return
    }

    let recentNotes = store.liveNotes.suffix(3).flatMap { $0.bullets }
    let previousLastID = lastNotedChunkID
    lastNotedChunkID = newLastID
    noteUpdateInFlight = true
    let generation = sessionGeneration

    Task {
      await runLiveNoteUpdate(
        segment: segment,
        recentNotes: Array(recentNotes),
        noteStartTime: firstStart,
        previousLastID: previousLastID,
        generation: generation
      )
      await MainActor.run {
        // Ignore a straggler from a previous session — clearing the flag here would defeat the
        // single-flight guard for the meeting that's now running.
        guard generation == self.sessionGeneration else { return }
        self.noteUpdateInFlight = false
      }
    }
  }

  /// Generates one note for the given segment and appends it to the store. Call from a Task.
  private func runLiveNoteUpdate(
    segment: String, recentNotes: [String], noteStartTime: TimeInterval, previousLastID: UUID?,
    generation: Int
  ) async {
    let model = PromptModel.loadSelectedMeetingSummary()
    guard model.hasRequiredCredential else {
      DebugLogger.logWarning(
        "LIVE-MEETING-NOTES: No credential for \(model.rawValue) — skipping live note")
      return
    }
    do {
      let raw = try await MeetingListService.generateLiveNote(
        segment: segment, recentNotes: recentNotes, model: model)
      let bullets = Self.parseBullets(raw)
      await MainActor.run {
        // A straggler from a previous session must not write into the current meeting's state —
        // and neither may a note that lands after this meeting ended. `sessionGeneration` alone
        // does not catch that: it only changes at the next `start()`, so a generation still looks
        // current while the meeting is being wrapped up. Writing then would re-persist the whole
        // store over a file the user may already have hand-edited from the ended-meeting view.
        guard self.isLive(generation) else {
          DebugLogger.log("LIVE-MEETING-NOTES: Dropping note for a meeting that is no longer live")
          return
        }
        self.consecutiveNoteFailures = 0
        // An empty response is a valid answer: the prompt tells the model to stay silent when a
        // segment carries nothing worth remembering. The segment still counts as noted.
        guard !bullets.isEmpty else {
          DebugLogger.log("LIVE-MEETING-NOTES: Segment produced no note (nothing noteworthy)")
          return
        }
        LiveMeetingTranscriptStore.shared.appendNote(
          LiveMeetingNote(startTime: noteStartTime, bullets: bullets))
        self.persistNotes()
        DebugLogger.log("LIVE-MEETING-NOTES: Appended note with \(bullets.count) bullet(s)")
      }
    } catch {
      DebugLogger.logError("LIVE-MEETING-NOTES: Note generation failed: \(error.logDescription)")
      await MainActor.run {
        guard generation == self.sessionGeneration else { return }
        // Roll back so the next attempt covers the same segment.
        self.lastNotedChunkID = previousLastID
        self.consecutiveNoteFailures += 1
        // Trip the circuit-breaker after sustained failures: stop hammering the model for the
        // rest of the session and tell the user once (the final summary is still attempted at end).
        if self.consecutiveNoteFailures >= self.noteFailureThreshold && !self.noteCircuitOpen {
          self.noteCircuitOpen = true
          DebugLogger.logWarning(
            "LIVE-MEETING-NOTES: circuit-breaker tripped after \(self.consecutiveNoteFailures) consecutive failures — pausing live notes for this session"
          )
          if !self.didShowNoteFailureAlert {
            self.didShowNoteFailureAlert = true
            PopupNotificationWindow.showError(
              "Live notes couldn't be generated (the notes model is unavailable). Recording continues normally; a full summary will be generated when the meeting ends.",
              title: "Live Meeting – Notes Paused"
            )
          }
        }
      }
    }
  }

  /// Writes the current note list next to the transcript so it survives a restart and a reopen.
  private func persistNotes() {
    guard let url = transcriptURL else { return }
    MeetingListService.shared.saveNotes(
      LiveMeetingTranscriptStore.shared.liveNotes, transcriptFileURL: url)
  }

  /// Extracts bullet lines from a live-note response. Models occasionally answer with a bare
  /// sentence instead of "- …", so an unbulleted single line is accepted as one bullet.
  static func parseBullets(_ raw: String) -> [String] {
    let lines = raw.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let bulleted = lines.compactMap { line -> String? in
      for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
        let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
      }
      return nil
    }
    if !bulleted.isEmpty { return Array(bulleted.prefix(2)) }
    // No bullet markers: accept a single plain line, but never a whole paragraph dump.
    guard lines.count == 1, let only = lines.first, only.count <= 300 else { return [] }
    return [only]
  }

  // MARK: - Chunk cadence

  /// Switches the recorder between the responsive cadence (chat window on screen, so the note
  /// stream is being watched) and the configured one. A 60 s chunk means the live view can lag a
  /// full minute behind the room — fine in the background, far too slow to follow along.
  func setFastChunking(_ fast: Bool) {
    guard let recorder else { return }
    let configured = Self.configuredChunkInterval()
    let target = fast ? min(configured, AppConstants.liveMeetingFastChunkInterval) : configured
    let minimum = fast
      ? min(AppConstants.liveMeetingFastChunkMinDuration, AppConstants.liveMeetingChunkMinDuration)
      : AppConstants.liveMeetingChunkMinDuration
    recorder.updateCadence(maxChunkDuration: target, minChunkDuration: minimum)
  }

  // MARK: - Flush on demand

  /// Cuts the audio that is still in the recorder and waits (briefly) for its transcript, so a
  /// question asked about the last few seconds can actually be answered from them.
  ///
  /// Without this the newest chunk is invisible to the chat for up to a full cadence interval: the
  /// user hears a question in the room, asks about it, and the model is shown a transcript that stops
  /// before it was asked. The wait is capped because a question must never hang on the network — when
  /// the cap hits, the turn simply goes out with whatever had landed, and the flushed chunk still
  /// arrives in the transcript moments later.
  @MainActor
  func flushPendingAudio(timeout: TimeInterval = 3.0) async {
    guard appStateIsRecordingMeeting(), let recorder, let cutIndex = recorder.rotateNow() else {
      return
    }
    DebugLogger.log("LIVE-MEETING: Flushing pending audio (chunk \(cutIndex)) before the user's turn")
    flushAwaitedChunkIndex = cutIndex
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let id = UUID()
      flushWaiters[id] = continuation
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
        guard let waiter = self?.flushWaiters.removeValue(forKey: id) else { return }
        DebugLogger.log("LIVE-MEETING: Flush wait timed out after \(Int(timeout))s")
        waiter.resume()
      }
    }
  }

  /// Releases everything waiting on `flushPendingAudio()`.
  ///
  /// `completedChunkIndex` is the chunk whose pipeline just finished; a chunk older than the flushed
  /// one does not count, because a slow predecessor finishing first would release the waiter before
  /// the text it is actually waiting for exists. Pass nil for "nothing further is coming" (the
  /// session ended, or the delivery arrived after finalization), which always releases.
  private func signalFlushCompleted(completedChunkIndex: Int?) {
    guard !flushWaiters.isEmpty else { return }
    if let awaited = flushAwaitedChunkIndex, let done = completedChunkIndex, done < awaited {
      return
    }
    flushAwaitedChunkIndex = nil
    let waiters = flushWaiters
    flushWaiters = [:]
    waiters.values.forEach { $0.resume() }
  }

  private static func configuredChunkInterval() -> TimeInterval {
    let saved = UserDefaults.standard.double(forKey: UserDefaultsKeys.liveMeetingChunkInterval)
    return saved > 0 ? saved : SettingsDefaults.liveMeetingChunkInterval.rawValue
  }
}

// MARK: - LiveMeetingRecorderDelegate

extension LiveMeetingSession: LiveMeetingRecorderDelegate {
  func liveMeetingRecorder(
    didFinishChunk audioURL: URL, chunkIndex: Int, startTime: TimeInterval, isSilent: Bool,
    isFinal: Bool
  ) {
    DebugLogger.log(
      "LIVE-MEETING: Received chunk \(chunkIndex) at \(Self.formatTimestamp(elapsedSeconds: startTime))\(isSilent ? " (silent)" : "")\(isFinal ? " (final)" : "")"
    )

    // Heartbeat for the recording marker: tells the next launch when the app was last alive.
    if !finalized && recorder != nil && !stopping {
      LiveMeetingRecordingMarker.touch()
    }

    // Drop late deliveries that arrive after the session was finalized.
    if finalized {
      DebugLogger.logWarning(
        "LIVE-MEETING: Dropping late chunk \(chunkIndex) (session already finalized)")
      cleanUpAudioFile(audioURL)
      signalFlushCompleted(completedChunkIndex: nil)
      return
    }

    if isFinal {
      awaitingFinalChunk = false
    }

    if isSilent {
      DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent audio)")
      cleanUpAudioFile(audioURL)
      // A silent chunk produces no text, but it still settles what a flush was waiting for.
      signalFlushCompleted(completedChunkIndex: chunkIndex)
      maybeFinishAfterChunkCompletion()
      return
    }

    pendingChunks += 1
    // Captured now: the transcript file and the bookkeeping belong to this meeting. The call can
    // outlive `finish()` (which clears `transcriptURL`) and a later `start()` (which reuses this
    // object). A late success must not write into the new meeting or decrement its pending count.
    let generation = sessionGeneration
    let chunkTranscriptURL = transcriptURL

    Task {
      do {
        let text = try await transcribeChunk(audioURL)

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedText.isEmpty {
          DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent)")
        } else {
          await MainActor.run {
            // Appending also evaluates whether the accumulated segment is worth a live note.
            self.appendToTranscript(
              trimmedText, chunkStartTime: startTime, url: chunkTranscriptURL, generation: generation)
          }
        }

        cleanUpAudioFile(audioURL)

      } catch TranscriptionError.noSpeechDetected {
        DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (no speech detected)")
        cleanUpAudioFile(audioURL)
      } catch {
        DebugLogger.logError("LIVE-MEETING: Chunk \(chunkIndex) transcription failed: \(error)")
        let isRateLimitOrQuota: Bool = {
          if let te = error as? TranscriptionError {
            switch te {
            case .rateLimited, .quotaExceeded: return true
            default: return false
            }
          }
          return false
        }()
        // Keep the audio: losing a meeting because the Wi-Fi dropped is not acceptable, and the
        // chunk can be transcribed later at its original timestamp.
        // The backlog folder follows the meeting's name as it is now: renamed at End, or none when
        // the meeting was discarded.
        let stem = await MainActor.run {
          self.destination(forChunkOf: generation, capturedURL: chunkTranscriptURL)?.url
            .deletingPathExtension().lastPathComponent
        }
        let kept = stem.map {
          MeetingAudioBacklog.retain(audioURL, stem: $0, startTime: startTime)
        } ?? false
        if !kept { cleanUpAudioFile(audioURL) }
        await MainActor.run {
          if kept { self.onBacklogChanged() }
          // A failure for a meeting that has ended (stopped, or replaced by a newer one) must not
          // tell the user "Recording continues" or consume the current meeting's one-shot alerts.
          // The kept audio still needs a word: nothing else will mention it.
          guard self.isLive(generation) else {
            if kept, self.endedMeetingAlertShown.insert(generation).inserted {
              self.showEndedMeetingAlert(Self.endedMeetingFailureMessage(error: error))
            }
            return
          }
          if isRateLimitOrQuota {
            if !self.didShowRateLimitAlert {
              self.didShowRateLimitAlert = true
              self.didShowTranscriptionFailureAlert = true
              PopupNotificationWindow.showError(
                verbatim: SpeechErrorFormatter.formatForUser(error)
                  + (kept
                    ? String(localized: "\n\nThe meeting audio is kept on this Mac and can be transcribed later.")
                    : ""),
                title: "Live Meeting – Quota Reached"
              )
            }
          } else if !self.didShowTranscriptionFailureAlert {
            self.didShowTranscriptionFailureAlert = true
            PopupNotificationWindow.showError(
              verbatim: Self.chunkFailureMessage(error: error, kept: kept),
              title: "Live Meeting – Transcription Failed"
            )
          }
        }
      }

      await MainActor.run {
        guard self.isLive(generation) else {
          DebugLogger.log(
            "LIVE-MEETING: Chunk \(chunkIndex) finished after its meeting ended; leaving pending count and flush state alone"
          )
          return
        }
        self.pendingChunks -= 1
        // Transcribed, empty, or failed — either way this chunk is settled, so a flush waiting on it
        // may proceed with whatever landed.
        self.signalFlushCompleted(completedChunkIndex: chunkIndex)
        self.maybeFinishAfterChunkCompletion()
      }
    }
  }

  /// Called whenever a chunk's pending work completes. Finalizes the session once
  /// the user has requested stop, all pending chunks have completed, and the
  /// recorder has delivered its final chunk (tracked via `awaitingFinalChunk`).
  private func maybeFinishAfterChunkCompletion() {
    guard stopping else { return }
    guard pendingChunks == 0 else { return }
    guard !awaitingFinalChunk else { return }
    finish()
  }

  func liveMeetingRecorderDidEndWithoutFinalChunk() {
    DebugLogger.log("LIVE-MEETING: Recorder ended without a final chunk")
    awaitingFinalChunk = false
    maybeFinishAfterChunkCompletion()
  }

  func liveMeetingRecorder(didFailWithError error: Error) {
    DebugLogger.logError("LIVE-MEETING: Recorder error: \(error)")

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }

      // Don't abort immediately - just log the error
      // If it's a critical error, the recorder will stop on its own
      if !self.isActive {
        return
      }

      // Microphone permission denied/restricted: offer a direct jump to the Microphone
      // privacy pane instead of leaving the user with only "Contact Support".
      let nsError = error as NSError
      if nsError.domain == "LiveMeetingRecorder" && nsError.code == 2001 {
        PopupNotificationWindow.showError(
          "WhisperShortcut needs microphone access to record. Open System Settings ▸ Privacy & Security ▸ Microphone and enable WhisperShortcut.",
          title: "Microphone Access Needed",
          retryAction: { PermissionStatusChecker.requestThenOpenSystemSettings(for: .microphone) },
          retryActionTitle: "Open System Settings"
        )
        return
      }

      // Show error but don't stop the session
      PopupNotificationWindow.showError(
        verbatim: SpeechErrorFormatter.formatForUser(error), title: "Live Meeting")
    }
  }
}
