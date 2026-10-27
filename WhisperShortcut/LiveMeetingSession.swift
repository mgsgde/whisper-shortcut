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
/// One instance is kept for the app's lifetime and reused across meetings. Everything that belongs
/// to ONE meeting lives in a `MeetingRun`; starting (or resuming) a meeting creates a fresh run and
/// finishing drops it in one place. Every Task, timer and callback that touches per-meeting state
/// captures the run it was launched under and does nothing when that run is no longer `currentRun`,
/// so work that outlives its meeting (a slow chunk transcription, the stop safety-net timer, a live
/// note) can never reach the next or a resumed meeting.
final class LiveMeetingSession: NSObject {

  // MARK: - Run / phase

  /// All state of one recording run (start or resume until finish). Reference identity is the
  /// run's identity: `run === currentRun` replaces the old `sessionGeneration` counter.
  final class MeetingRun {
    let id = UUID()
    var recorder: LiveMeetingRecorder?
    var transcriptURL: URL?
    /// Set on stop; cleared when the recorder delivers its final chunk. Gates `finish` so
    /// post-processing can't start before the last audio arrives.
    var awaitingFinalChunk = false
    var pendingChunks = 0
    var safeguardTimer: Timer?
    /// When non-nil, finish renames the transcript to this stem (or timestamp-suffix).
    var preferredName: String?
    /// When true, finish deletes the transcript instead of saving.
    var discard = false
    /// ID of the last chunk already covered by a live note. Robust against chunk trimming.
    var lastNotedChunkID: UUID?
    var didShowRateLimitAlert = false
    var didShowTranscriptionFailureAlert = false
    var consecutiveNoteFailures = 0
    /// True once the live-note circuit-breaker has tripped for this run.
    var noteCircuitOpen = false
    var didShowNoteFailureAlert = false
    /// Single-flight guard for live-note API calls.
    var noteUpdateInFlight = false
    /// Callers of `flushPendingAudio()` waiting for the chunk that flush cut, keyed so a timeout
    /// can drop its own waiter without disturbing the others.
    var flushWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Index of the chunk the pending flush cut; see `signalFlushCompleted`.
    var flushAwaitedChunkIndex: Int?
  }

  /// Lifecycle of the session. `.draining` = stop requested, waiting for the last chunk(s).
  enum Phase {
    case idle
    case recording(MeetingRun)
    case draining(MeetingRun)
  }

  private(set) var phase: Phase = .idle

  var currentRun: MeetingRun? {
    switch phase {
    case .idle: return nil
    case .recording(let run), .draining(let run): return run
    }
  }

  private func isCurrent(_ run: MeetingRun) -> Bool { currentRun === run }

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

  init(
    transcribeChunk: @escaping (URL) async throws -> String,
    cleanUpAudioFile: @escaping (URL) -> Void,
    appStateIsRecordingMeeting: @escaping () -> Bool,
    onStopping: @escaping () -> Void,
    onFinished: @escaping () -> Void,
    onBacklogChanged: @escaping () -> Void
  ) {
    self.transcribeChunk = transcribeChunk
    self.cleanUpAudioFile = cleanUpAudioFile
    self.appStateIsRecordingMeeting = appStateIsRecordingMeeting
    self.onStopping = onStopping
    self.onFinished = onFinished
    self.onBacklogChanged = onBacklogChanged
    super.init()
  }

  // MARK: - Session state

  /// True while `retryBacklog` runs, so a second click can't transcribe the same files twice.
  private(set) var isRetryingBacklog: Bool = false
  /// Retry requests that arrived while a pass was running; one more pass handles them.
  private var hasPendingRetry = false
  private var pendingRetryStems: Set<String> = []
  private var pendingRetryAll = false
  private var pendingRetryAnnounce = false
  /// Consecutive live-note failures before the circuit-breaker opens and we notify the user.
  private let noteFailureThreshold = 3
  /// Minimum new transcript characters before a live note is generated. Below this a segment is
  /// usually a greeting or a stray sentence and produces a note not worth its API call.
  private let liveNoteMinChars = 400
  /// …unless this many chunks have piled up, which happens when people speak in short bursts.
  private let liveNoteMaxPendingChunks = 4
  /// True while this session holds a recorder. Combined with `appState` by the owner to decide
  /// whether a meeting is active.
  var isRecording: Bool { currentRun?.recorder != nil }

  /// True when a meeting is active (recording, or stopping with pending chunks).
  private var isActive: Bool { appStateIsRecordingMeeting() || currentRun?.recorder != nil }

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
    let transcriptURL: URL
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

    // A fresh run for every start/resume. Whatever run was still current is orphaned: its Tasks and
    // timers see `run !== currentRun` and no-op.
    if let previous = currentRun {
      DebugLogger.logWarning("LIVE-MEETING: Starting while run \(previous.id) was still current; orphaning it")
      previous.recorder?.stopSession()
      previous.safeguardTimer?.invalidate()
      previous.safeguardTimer = nil
    }
    let run = MeetingRun()
    run.transcriptURL = transcriptURL

    // Create and start recorder
    let newRecorder = LiveMeetingRecorder(maxChunkDuration: chunkInterval)
    newRecorder.delegate = self
    run.recorder = newRecorder
    phase = .recording(run)
    newRecorder.startSession(resumeTimeOffset: resumeOffset)

    if resuming && !existingChunks.isEmpty {
      LiveMeetingTranscriptStore.shared.resumeSession()
      // Everything already on disk has been noted; only new chunks need a note.
      run.lastNotedChunkID = existingChunks.last?.id
    } else {
      LiveMeetingTranscriptStore.shared.startSession()
      run.lastNotedChunkID = nil
    }

    // Schedule duration safeguard if enabled
    let safeguardThreshold = MeetingSafeguardDuration.loadFromUserDefaults()
    if safeguardThreshold != .never {
      let timer = Timer.scheduledTimer(
        withTimeInterval: safeguardThreshold.rawValue, repeats: false
      ) { [weak self, weak run] _ in
        guard let self, let run else { return }
        self.showSafeguardAlert(
          run: run, thresholdMinutes: Int(safeguardThreshold.rawValue / 60))
      }
      run.safeguardTimer = timer
      RunLoop.main.add(timer, forMode: .common)
      DebugLogger.log(
        "LIVE-MEETING-SAFEGUARD: Reminder scheduled after \(Int(safeguardThreshold.rawValue / 60)) minutes"
      )
    }

    warnIfTranscriptionUnreachable(run: run)

    LiveMeetingRecordingMarker.write(stem: transcriptURL.deletingPathExtension().lastPathComponent)

    DebugLogger.logSuccess("LIVE-MEETING: Session started")
    return true
  }

  /// Records the user's meeting name / discard choice, then stops. Posted by the in-window
  /// "end meeting" affordance.
  func end(preferredName name: String?, discard shouldDiscard: Bool) {
    guard let run = currentRun else { return stopWithoutRun() }
    run.preferredName = name
    run.discard = shouldDiscard
    stop(run: run)
  }

  /// Called when the app is about to exit while a meeting is recording (system quit, update
  /// script, logout). Keeps the chunk in progress in the audio backlog so it is transcribed when the
  /// meeting is resumed or ended, instead of vanishing with the process. The recording marker is
  /// left in place on purpose: the next launch reads it to resume or report the interruption.
  func preserveForTermination() {
    guard case .recording(let run) = phase, let recorder = run.recorder else { return }
    let stem = run.transcriptURL?.deletingPathExtension().lastPathComponent
    let chunk = recorder.stopForTermination()
    run.recorder = nil
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
    guard let run = currentRun else { return stopWithoutRun() }
    stop(run: run)
  }

  /// Stop or end with no run: nothing to drain. If the owner still shows a meeting, report it
  /// finished right away. Otherwise it is a late or duplicate request (double click, stale end
  /// button) and must not touch app state — a 30 s fake drain here used to reset a dictation the
  /// user had started meanwhile to `.idle`, or leave "Finishing meeting" on through the next one.
  private func stopWithoutRun() {
    // The recording marker is left alone: with no run this process wrote none, and one left by a
    // crashed earlier process is what the next launch needs to offer the resume.
    guard appStateIsRecordingMeeting() else {
      DebugLogger.log("LIVE-MEETING: Stop requested with no meeting run — ignoring")
      return
    }
    DebugLogger.logWarning("LIVE-MEETING: Stop requested with no meeting run while app state shows one — finishing now")
    onFinished()
  }

  private func stop(run: MeetingRun) {
    DebugLogger.log("LIVE-MEETING: User requested stop")
    LiveMeetingRecordingMarker.clear()

    run.safeguardTimer?.invalidate()
    run.safeguardTimer = nil
    // Tell the UI *now*: the drain below needs a transcription round trip, and until it lands both
    // the menu bar and the meeting bar would otherwise keep claiming the meeting is recording.
    LiveMeetingTranscriptStore.shared.beginFinishing()
    onStopping()
    enterDraining(run)
  }

  /// Switches `run` to draining, asks the recorder for its final chunk and arms the safety net.
  /// AVAudioRecorder delivers its final chunk async via audioRecorderDidFinishRecording, so
  /// finalizing waits for it (prevents post-processing rewriting the transcript file while a late
  /// chunk is still being appended).
  private func enterDraining(_ run: MeetingRun) {
    phase = .draining(run)
    run.awaitingFinalChunk = true
    run.recorder?.stopSession()

    // Safety net: if the final chunk never arrives within 30s, finish anyway so the UI
    // doesn't get stuck in "stopping" forever. Bound to THIS run: a timer from a meeting that has
    // since finished (or been resumed) must not touch the one that is running now.
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      self?.safetyNetFired(for: run)
    }
  }

  // MARK: - Test seams

  /// Starts a recorder-less run on `transcriptURL`, orphaning any current one exactly like
  /// `start(resuming:)` does. Lets tests drive the chunk pipeline without a microphone, the
  /// transcript store or the recording marker.
  func beginRunForTesting(transcriptURL: URL) -> MeetingRun {
    let run = MeetingRun()
    run.transcriptURL = transcriptURL
    phase = .recording(run)
    return run
  }

  /// Moves `run` to draining without the stop side effects (marker, store, owner callbacks, timer).
  func markDrainingForTesting(_ run: MeetingRun) {
    phase = .draining(run)
    run.awaitingFinalChunk = true
  }

  func safetyNetFired(for run: MeetingRun) {
    guard isCurrent(run), case .draining = phase else {
      DebugLogger.log("LIVE-MEETING: Stale stop safety net for run \(run.id) ignored")
      return
    }
    DebugLogger.logWarning("LIVE-MEETING: Final chunk timeout; finishing session anyway")
    run.awaitingFinalChunk = false
    run.pendingChunks = 0
    finish(run)
  }

  private func showSafeguardAlert(run: MeetingRun, thresholdMinutes: Int) {
    run.safeguardTimer?.invalidate()
    run.safeguardTimer = nil

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard self.isCurrent(run) else {
        DebugLogger.log("LIVE-MEETING-SAFEGUARD: Stale reminder for run \(run.id) ignored")
        return
      }
      if !self.isActive {
        return
      }
      DebugLogger.log(
        "LIVE-MEETING-SAFEGUARD: Showing duration prompt after \(thresholdMinutes) minutes")
      let alert = NSAlert()
      alert.messageText = String(localized: "Long meeting")
      alert.informativeText =
        "This meeting has been transcribing for over \(thresholdMinutes) minutes. Stop or continue?"
      alert.alertStyle = .informational
      alert.addButton(withTitle: String(localized: "Stop meeting"))
      alert.addButton(withTitle: String(localized: "Continue"))
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        guard self.isCurrent(run) else { return }
        DebugLogger.log("LIVE-MEETING-SAFEGUARD: User chose to stop meeting")
        self.stop()
      } else {
        DebugLogger.log("LIVE-MEETING-SAFEGUARD: User chose to continue")
      }
    }
  }

  private func finish(_ run: MeetingRun) {
    guard isCurrent(run), case .draining = phase else {
      DebugLogger.log("LIVE-MEETING: finish ignored (run \(run.id) is not the draining run)")
      return
    }
    // The ONE place a run ends: the phase drops to idle, so every late callback of this run (and
    // any chunk the recorder still delivers) is dropped by the identity / phase checks.
    phase = .idle
    LiveMeetingRecordingMarker.clear()
    #if !APP_STORE && canImport(Sparkle)
    Task { @MainActor in UpdaterService.shared.showDeferredUpdateIfAny() }
    #endif

    let shouldDiscard = run.discard
    DebugLogger.log("LIVE-MEETING: Session finished (discard=\(shouldDiscard))")

    if shouldDiscard {
      if let url = run.transcriptURL {
        try? FileManager.default.removeItem(at: url)
        let summaryURL = url.deletingPathExtension().appendingPathExtension("summary.md")
        try? FileManager.default.removeItem(at: summaryURL)
        try? FileManager.default.removeItem(at: MeetingListService.notesURL(transcriptFileURL: url))
        MeetingAudioBacklog.remove(stem: url.deletingPathExtension().lastPathComponent)
        DebugLogger.log("LIVE-MEETING: Discarded transcript, notes, summary and kept audio")
      }
      run.transcriptURL = nil
      LiveMeetingTranscriptStore.shared.clearForNewMeeting()
      MeetingListService.shared.refresh()
    } else {
      if let url = run.transcriptURL, let preferred = run.preferredName, !preferred.isEmpty {
        let currentStem = url.deletingPathExtension().lastPathComponent
        if preferred != currentStem {
          renameTranscriptFile(run: run, from: url, preferredName: preferred, currentStem: currentStem)
        }
      }
      LiveMeetingTranscriptStore.shared.endSession()
    }

    // Capture URL for the post-processing Task before the run is torn down.
    let transcriptURLForPostProcessing: URL? = shouldDiscard ? nil : run.transcriptURL

    run.safeguardTimer?.invalidate()
    run.safeguardTimer = nil
    run.awaitingFinalChunk = false
    run.recorder = nil
    run.pendingChunks = 0
    // The meeting is over, so nothing further will arrive for a waiter to wait on.
    signalFlushCompleted(run, completedChunkIndex: nil)
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

  private func runPostProcessing(
    transcriptURL: URL, chunks chunksSnapshot: [LiveMeetingChunk]
  ) {
    Task {
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
      guard model.hasRequiredCredential else {
        DebugLogger.logWarning(
          "LIVE-MEETING: No credential for \(model.rawValue) — skipping post-processing")
        return
      }

      // Skip consolidation when the transcript has at most one distinct speaker — there is nothing
      // to reconcile, and the pass echoes the whole transcript back as (paid) output. When it runs,
      // route to the provider's cheapest model: relabeling is mechanical and doesn't need the
      // summary model's quality.
      var finalTranscript = transcriptText
      if MeetingListService.skipsSpeakerConsolidation(provider: model.provider) {
        DebugLogger.log(
          "LIVE-MEETING: Skipping speaker consolidation (on-device summary model \(model.rawValue))")
      } else if MeetingListService.distinctSpeakerCount(in: transcriptText) >= 2 {
        do {
          let consolidated = try await MeetingListService.consolidateSpeakerLabels(
            transcript: transcriptText, model: model.speakerConsolidationModel)
          let trimmed = consolidated.trimmingCharacters(in: .whitespacesAndNewlines)
          if !Self.acceptsConsolidation(original: transcriptText, consolidated: trimmed) {
            DebugLogger.logWarning(
              "LIVE-MEETING: Speaker consolidation rejected (timestamps differ or empty) — keeping original transcript")
          } else {
            finalTranscript = trimmed
            if let data = trimmed.data(using: .utf8) {
              try data.write(to: transcriptURL, options: .atomic)
            }
            await MainActor.run {
              MeetingListService.shared.invalidateCache(for: nil)
            }
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
      var textForSummary = finalTranscript
      if textForSummary.count > MeetingListService.meetingContextMaxChars {
        textForSummary = String(textForSummary.suffix(MeetingListService.meetingContextMaxChars))
      }
      do {
        let summary = try await MeetingListService.generateSummaryText(
          transcript: textForSummary, model: model)
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          MeetingListService.shared.saveSummary(trimmed, transcriptFileURL: transcriptURL)
          DebugLogger.log("LIVE-MEETING: Summary saved to .summary.md")
          // Push the fresh summary to the chat sidebar so it can derive a meeting title live
          // (ChatView subscribes to .chatMeetingSummaryReady; without this it relies on the
          // slower backfill recovery path).
          let stem = transcriptURL.deletingPathExtension().lastPathComponent
          await MainActor.run {
            NotificationCenter.default.post(
              name: .chatMeetingSummaryReady, object: nil,
              userInfo: ["stem": stem, "summary": trimmed])
          }
        }
      } catch {
        DebugLogger.logError("LIVE-MEETING: Generate summary failed: \(error.logDescription)")
        // Don't lose the summary silently: the transcript is saved, so tell the user it can be
        // regenerated from the meeting library (the recovery path handles a transient outage).
        let offline = OfflineMode.isEnabled
        await MainActor.run {
          PopupNotificationWindow.showError(
            verbatim: offline
              ? "The meeting transcript was saved, but the summary couldn't be generated because no on-device summary model is available. Pick one in Settings → Meetings → Meeting Summary Model; you can then regenerate the summary from the meeting library."
              : "The meeting transcript was saved, but the summary couldn't be generated (the summary model is unavailable). You can regenerate it from the meeting library when the service is back.",
            title: "Live Meeting – Summary Failed"
          )
        }
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

  /// Warns the moment a meeting starts without a network path, instead of a chunk interval later.
  /// An on-device transcription model needs no network, so it is never warned about.
  private func warnIfTranscriptionUnreachable(run: MeetingRun) {
    guard !TranscriptionModel.loadSelectedForMeeting().isOffline else { return }
    let monitor = NWPathMonitor()
    var answered = false
    monitor.pathUpdateHandler = { [weak self] path in
      monitor.cancel()
      let isOnline = path.status == .satisfied
      DispatchQueue.main.async {
        guard !answered else { return }
        answered = true
        guard let self, !isOnline, self.isCurrent(run),
          self.appStateIsRecordingMeeting(), !run.didShowTranscriptionFailureAlert
        else { return }
        run.didShowTranscriptionFailureAlert = true
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
    let activeStem = currentRun?.recorder != nil
      ? currentRun?.transcriptURL?.deletingPathExtension().lastPathComponent : nil
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
          ? "The kept meeting audio contained no speech."
          : "The meeting transcript is complete again. The summary is being regenerated.",
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
  private func renameTranscriptFile(run: MeetingRun, from url: URL, preferredName: String, currentStem: String) {
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
      run.transcriptURL = newURL
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

  /// Appends a transcribed chunk to the run's OWN transcript file — never to whatever meeting is
  /// current — so text that arrives after its run ended still lands in the right meeting. The
  /// in-memory store and the live notes belong to the current meeting only, so a run that is no
  /// longer current leaves them alone.
  func appendToTranscript(run: MeetingRun, _ text: String, chunkStartTime: TimeInterval) {
    guard let url = run.transcriptURL else { return }

    var finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let timestamp = Self.formatTimestamp(elapsedSeconds: chunkStartTime)
    finalText = "\(timestamp) \(finalText)"
    finalText = "\(finalText)\n\n"

    do {
      let handle = try FileHandle(forWritingTo: url)
      handle.seekToEndOfFile()
      if let data = finalText.data(using: .utf8) {
        handle.write(data)
      }
      try handle.close()
      DebugLogger.log("LIVE-MEETING: Appended chunk to transcript")
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to append to transcript: \(error)")
    }

    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isCurrent(run) else {
      DebugLogger.log("LIVE-MEETING: Late chunk for finished run \(run.id) written to its own transcript only")
      return
    }
    if !trimmedText.isEmpty {
      LiveMeetingTranscriptStore.shared.appendChunk(startTime: chunkStartTime, text: trimmedText)
      // `appendChunk` hops to the main queue, so the new chunk isn't visible yet — evaluate the
      // note threshold after it lands.
      DispatchQueue.main.async { [weak self] in self?.refreshLiveNotes() }
    }
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
    guard appStateIsRecordingMeeting(), let run = currentRun else { return }

    // Circuit-breaker: after repeated failures (e.g. a sustained model outage) we stop generating
    // notes for the rest of the session instead of retrying for an hour. The end-of-meeting summary
    // is still attempted once in finish().
    guard !run.noteCircuitOpen else { return }

    // Single-flight: a second concurrent call would race on `lastNotedChunkID` and either duplicate
    // or skip a segment. Whatever is pending is picked up by the next append.
    guard !run.noteUpdateInFlight else { return }

    let store = LiveMeetingTranscriptStore.shared
    let pending = store.chunks(afterID: run.lastNotedChunkID)
    guard let newLastID = pending.last?.id, let firstStart = pending.first?.startTime else { return }

    let segment = pending.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n")
    guard !segment.isEmpty else { return }
    if !force && segment.count < liveNoteMinChars && pending.count < liveNoteMaxPendingChunks {
      return
    }

    let recentNotes = store.liveNotes.suffix(3).flatMap { $0.bullets }
    let previousLastID = run.lastNotedChunkID
    run.lastNotedChunkID = newLastID
    run.noteUpdateInFlight = true

    Task {
      await runLiveNoteUpdate(
        segment: segment,
        recentNotes: Array(recentNotes),
        noteStartTime: firstStart,
        previousLastID: previousLastID,
        run: run
      )
      // The flag lives on the run, so a straggler can only ever clear its own run's flag.
      await MainActor.run { run.noteUpdateInFlight = false }
    }
  }

  /// Generates one note for the given segment and appends it to the store. Call from a Task.
  private func runLiveNoteUpdate(
    segment: String, recentNotes: [String], noteStartTime: TimeInterval, previousLastID: UUID?,
    run: MeetingRun
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
        // A straggler from a previous run must not write into the current meeting's state.
        guard self.isCurrent(run) else {
          DebugLogger.log("LIVE-MEETING-NOTES: Dropping note from finished run \(run.id)")
          return
        }
        run.consecutiveNoteFailures = 0
        // An empty response is a valid answer: the prompt tells the model to stay silent when a
        // segment carries nothing worth remembering. The segment still counts as noted.
        guard !bullets.isEmpty else {
          DebugLogger.log("LIVE-MEETING-NOTES: Segment produced no note (nothing noteworthy)")
          return
        }
        LiveMeetingTranscriptStore.shared.appendNote(
          LiveMeetingNote(startTime: noteStartTime, bullets: bullets))
        self.persistNotes(run: run)
        DebugLogger.log("LIVE-MEETING-NOTES: Appended note with \(bullets.count) bullet(s)")
      }
    } catch {
      DebugLogger.logError("LIVE-MEETING-NOTES: Note generation failed: \(error.logDescription)")
      await MainActor.run {
        guard self.isCurrent(run) else {
          DebugLogger.log("LIVE-MEETING-NOTES: Dropping note failure from finished run \(run.id)")
          return
        }
        // Roll back so the next attempt covers the same segment.
        run.lastNotedChunkID = previousLastID
        run.consecutiveNoteFailures += 1
        // Trip the circuit-breaker after sustained failures: stop hammering the model for the
        // rest of the session and tell the user once (the final summary is still attempted at end).
        if run.consecutiveNoteFailures >= self.noteFailureThreshold && !run.noteCircuitOpen {
          run.noteCircuitOpen = true
          DebugLogger.logWarning(
            "LIVE-MEETING-NOTES: circuit-breaker tripped after \(run.consecutiveNoteFailures) consecutive failures — pausing live notes for this session"
          )
          if !run.didShowNoteFailureAlert {
            run.didShowNoteFailureAlert = true
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
  private func persistNotes(run: MeetingRun) {
    guard let url = run.transcriptURL else { return }
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
    guard let recorder = currentRun?.recorder else { return }
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
    guard appStateIsRecordingMeeting(), let run = currentRun, let recorder = run.recorder,
      let cutIndex = recorder.rotateNow()
    else {
      return
    }
    DebugLogger.log("LIVE-MEETING: Flushing pending audio (chunk \(cutIndex)) before the user's turn")
    run.flushAwaitedChunkIndex = cutIndex
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let id = UUID()
      run.flushWaiters[id] = continuation
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        guard let waiter = run.flushWaiters.removeValue(forKey: id) else { return }
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
  private func signalFlushCompleted(_ run: MeetingRun, completedChunkIndex: Int?) {
    guard !run.flushWaiters.isEmpty else { return }
    if let awaited = run.flushAwaitedChunkIndex, let done = completedChunkIndex, done < awaited {
      return
    }
    run.flushAwaitedChunkIndex = nil
    let waiters = run.flushWaiters
    run.flushWaiters = [:]
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
    if case .recording(let run) = phase, run.recorder != nil {
      LiveMeetingRecordingMarker.touch()
    }

    // Drop late deliveries that arrive when no run is active (after it was finalized).
    guard let run = currentRun else {
      DebugLogger.logWarning(
        "LIVE-MEETING: Dropping late chunk \(chunkIndex) (session already finalized)")
      cleanUpAudioFile(audioURL)
      return
    }

    if isFinal {
      run.awaitingFinalChunk = false
    }

    if isSilent {
      DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent audio)")
      cleanUpAudioFile(audioURL)
      // A silent chunk produces no text, but it still settles what a flush was waiting for.
      signalFlushCompleted(run, completedChunkIndex: chunkIndex)
      maybeFinishAfterChunkCompletion(run)
      return
    }

    run.pendingChunks += 1
    // Captured now: the backlog folder must match the stem this chunk belongs to, even if the
    // session finishes while the call is still out.
    let stem = run.transcriptURL?.deletingPathExtension().lastPathComponent

    Task {
      do {
        let text = try await transcribeChunk(audioURL)

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedText.isEmpty {
          DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent)")
        } else {
          await MainActor.run {
            // Appending also evaluates whether the accumulated segment is worth a live note.
            // It writes to the transcript of the run that recorded this chunk.
            self.appendToTranscript(run: run, trimmedText, chunkStartTime: startTime)
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
        // A run the user discarded keeps nothing — a retained chunk would bring the meeting back on
        // the next backlog retry. A renamed run retains under its new stem, not the one captured
        // at the start, so the retry doesn't split it into a second transcript.
        let currentStem = await MainActor.run {
          run.discard ? nil : (run.transcriptURL?.deletingPathExtension().lastPathComponent ?? stem)
        }
        let kept = currentStem.map {
          MeetingAudioBacklog.retain(audioURL, stem: $0, startTime: startTime)
        } ?? false
        if !kept { cleanUpAudioFile(audioURL) }
        await MainActor.run {
          if kept { self.onBacklogChanged() }
          // The popups are about the running meeting; a failure from a finished run is already
          // covered by its backlog retry.
          guard self.isCurrent(run) else { return }
          if isRateLimitOrQuota {
            if !run.didShowRateLimitAlert {
              run.didShowRateLimitAlert = true
              run.didShowTranscriptionFailureAlert = true
              PopupNotificationWindow.showError(
                verbatim: SpeechErrorFormatter.formatForUser(error)
                  + (kept ? "\n\nThe meeting audio is kept on this Mac and can be transcribed later." : ""),
                title: "Live Meeting – Quota Reached"
              )
            }
          } else if !run.didShowTranscriptionFailureAlert {
            run.didShowTranscriptionFailureAlert = true
            PopupNotificationWindow.showError(
              verbatim: Self.chunkFailureMessage(error: error, kept: kept),
              title: "Live Meeting – Transcription Failed"
            )
          }
        }
      }

      await MainActor.run {
        // The count belongs to the run that started this chunk; a run that already finished (its
        // safety net zeroed the count) must neither go negative nor drive the next meeting.
        run.pendingChunks = max(0, run.pendingChunks - 1)
        guard self.isCurrent(run) else {
          DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) completed after run \(run.id) ended")
          return
        }
        // Transcribed, empty, or failed — either way this chunk is settled, so a flush waiting on it
        // may proceed with whatever landed.
        self.signalFlushCompleted(run, completedChunkIndex: chunkIndex)
        self.maybeFinishAfterChunkCompletion(run)
      }
    }
  }

  /// Called whenever a chunk's pending work completes. Finalizes the run once the user has
  /// requested stop, all pending chunks have completed, and the recorder has delivered its final
  /// chunk (tracked via `awaitingFinalChunk`).
  private func maybeFinishAfterChunkCompletion(_ run: MeetingRun) {
    guard isCurrent(run), case .draining = phase else { return }
    guard run.pendingChunks == 0 else { return }
    guard !run.awaitingFinalChunk else { return }
    finish(run)
  }

  func liveMeetingRecorderDidEndWithoutFinalChunk() {
    DebugLogger.log("LIVE-MEETING: Recorder ended without a final chunk")
    guard let run = currentRun else { return }
    run.awaitingFinalChunk = false
    maybeFinishAfterChunkCompletion(run)
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
          retryAction: { PermissionStatusChecker.openSystemSettings(for: .microphone) },
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
