import AppKit
import Foundation

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

  init(
    transcribeChunk: @escaping (URL) async throws -> String,
    cleanUpAudioFile: @escaping (URL) -> Void,
    appStateIsRecordingMeeting: @escaping () -> Bool,
    onStopping: @escaping () -> Void,
    onFinished: @escaping () -> Void
  ) {
    self.transcribeChunk = transcribeChunk
    self.cleanUpAudioFile = cleanUpAudioFile
    self.appStateIsRecordingMeeting = appStateIsRecordingMeeting
    self.onStopping = onStopping
    self.onFinished = onFinished
    super.init()
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
  /// ID of the last chunk already covered by a live note. Robust against chunk trimming.
  private var lastNotedChunkID: UUID? = nil
  /// When non-nil, `finish()` renames the transcript file to this stem (or timestamp-suffix) before ending.
  private var preferredName: String?
  /// Set to true after showing the rate-limit popup once this session so we don't spam.
  private var didShowRateLimitAlert: Bool = false
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
  /// Bumped on every session start. A live-note Task captures the generation it launched under so a
  /// straggler from a previous meeting (its API call can outlive a stop+restart) no-ops instead of
  /// clearing the in-flight flag — or writing note/chunk state — for the newer session.
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

  /// True when a meeting is active (recording, or stopping with pending chunks).
  private var isActive: Bool { appStateIsRecordingMeeting() || recorder != nil }

  // MARK: - Lifecycle

  /// Creates the transcript file and starts the recorder. Returns false (after showing an error)
  /// when the transcript file can't be created, so the caller leaves `appState` untouched.
  func start(resuming: Bool) -> Bool {
    DebugLogger.log("LIVE-MEETING: Starting session (resuming=\(resuming))")

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

    // Update state
    stopping = false
    finalized = false
    awaitingFinalChunk = false
    pendingChunks = 0
    didShowRateLimitAlert = false
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

    DebugLogger.logSuccess("LIVE-MEETING: Session started")
    return true
  }

  /// Records the user's meeting name / discard choice, then stops. Posted by the in-window
  /// "end meeting" affordance.
  func end(preferredName name: String?, discard shouldDiscard: Bool) {
    preferredName = name
    discard = shouldDiscard
    stop()
  }

  func stop() {
    DebugLogger.log("LIVE-MEETING: User requested stop")

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

    // Safety net: if the final chunk never arrives within 30s, finish anyway so the UI
    // doesn't get stuck in "stopping" forever.
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      guard let self = self else { return }
      if self.stopping && !self.finalized {
        DebugLogger.logWarning("LIVE-MEETING: Final chunk timeout; finishing session anyway")
        self.awaitingFinalChunk = false
        self.pendingChunks = 0
        self.finish()
      }
    }
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
      alert.messageText = "Long meeting"
      alert.informativeText =
        "This meeting has been transcribing for over \(thresholdMinutes) minutes. Stop or continue?"
      alert.alertStyle = .informational
      alert.addButton(withTitle: "Stop meeting")
      alert.addButton(withTitle: "Continue")
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

    let shouldDiscard = discard
    DebugLogger.log("LIVE-MEETING: Session finished (discard=\(shouldDiscard))")

    if shouldDiscard {
      if let url = transcriptURL {
        try? FileManager.default.removeItem(at: url)
        let summaryURL = url.deletingPathExtension().appendingPathExtension("summary.md")
        try? FileManager.default.removeItem(at: summaryURL)
        try? FileManager.default.removeItem(at: MeetingListService.notesURL(transcriptFileURL: url))
        DebugLogger.log("LIVE-MEETING: Discarded transcript, notes and summary files")
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

    preferredName = nil
    safeguardTimer?.invalidate()
    safeguardTimer = nil
    stopping = false
    awaitingFinalChunk = false
    discard = false
    recorder = nil
    pendingChunks = 0
    transcriptURL = nil
    lastNotedChunkID = nil
    // The meeting is over, so nothing further will arrive for a waiter to wait on.
    signalFlushCompleted(completedChunkIndex: nil)
    onFinished()

    if let transcriptURL = transcriptURLForPostProcessing {
      runPostProcessing(transcriptURL: transcriptURL)
    }

    DebugLogger.logSuccess("LIVE-MEETING: Session cleanup complete")
  }

  /// End-of-meeting pass: consolidate speaker labels across the full transcript, then generate the
  /// final summary from it. Runs detached from the session's own state — everything it needs was
  /// captured before `finish()` cleared the fields.
  private func runPostProcessing(transcriptURL: URL) {
    let chunksSnapshot = LiveMeetingTranscriptStore.shared.chunks
    let markers = LiveMeetingTranscriptStore.shared.markerTexts
    Task {
      let transcriptText = chunksSnapshot.map { "\($0.timestampString) \($0.text)" }.joined(
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
      if MeetingListService.distinctSpeakerCount(in: transcriptText) >= 2 {
        do {
          let consolidated = try await MeetingListService.consolidateSpeakerLabels(
            transcript: transcriptText, model: model.speakerConsolidationModel)
          let trimmed = consolidated.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
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
          transcript: textForSummary, markers: markers, model: model)
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
        DebugLogger.logError("LIVE-MEETING: Generate summary failed: \(error.localizedDescription)")
        // Don't lose the summary silently: the transcript is saved, so tell the user it can be
        // regenerated from the meeting library (the recovery path handles a transient outage).
        await MainActor.run {
          PopupNotificationWindow.showError(
            "The meeting transcript was saved, but the summary couldn't be generated (the summary model is unavailable). You can regenerate it from the meeting library when the service is back.",
            title: "Live Meeting – Summary Failed"
          )
        }
      }
    }
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
      transcriptURL = newURL
      MeetingListService.shared.invalidateCache(for: nil)
      DispatchQueue.main.async {
        LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem = newStem
        LiveMeetingTranscriptStore.shared.preferredMeetingName = sanitized
      }
      DebugLogger.log("LIVE-MEETING: Renamed transcript to \(newStem).txt")
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to rename transcript: \(error.localizedDescription)")
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

  private func appendToTranscript(_ text: String, chunkStartTime: TimeInterval) {
    guard let url = transcriptURL else { return }

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

  /// Marks the current moment with a user-written (or default) marker and persists it.
  /// Called from the global marker hotkey while a meeting is recording.
  @discardableResult
  func addMarker(text: String) -> Bool {
    guard appStateIsRecordingMeeting() else { return false }
    let store = LiveMeetingTranscriptStore.shared
    let marker = store.appendMarker(text: text, at: recorder?.currentElapsedTime)
    persistNotes()
    DebugLogger.log("LIVE-MEETING-NOTES: Marker set at \(marker.timestampString)")
    return true
  }

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

    // Only generated notes are context for the model — markers are the user's own words and
    // repeating them back would just make the model echo them.
    let recentNotes = store.liveNotes.filter { !$0.isMarker }.suffix(3).flatMap { $0.bullets }
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
        // A straggler from a previous session must not write into the current meeting's state.
        guard generation == self.sessionGeneration else { return }
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
      DebugLogger.logError("LIVE-MEETING-NOTES: Note generation failed: \(error.localizedDescription)")
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

    Task {
      do {
        let text = try await transcribeChunk(audioURL)

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedText.isEmpty {
          DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent)")
        } else {
          await MainActor.run {
            // Appending also evaluates whether the accumulated segment is worth a live note.
            self.appendToTranscript(trimmedText, chunkStartTime: startTime)
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
        if isRateLimitOrQuota {
          await MainActor.run {
            if !self.didShowRateLimitAlert {
              self.didShowRateLimitAlert = true
              PopupNotificationWindow.showError(
                SpeechErrorFormatter.formatForUser(error),
                title: "Live Meeting – Quota Reached"
              )
            }
          }
        }
        cleanUpAudioFile(audioURL)
      }

      await MainActor.run {
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
          retryActionTitle: "Open Settings"
        )
        return
      }

      // Show error but don't stop the session
      PopupNotificationWindow.showError(
        SpeechErrorFormatter.formatForUser(error), title: "Live Meeting")
    }
  }
}
