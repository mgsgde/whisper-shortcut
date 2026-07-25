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
  /// The session has fully finished (saved or discarded); the owner returns `appState` to idle.
  private let onFinished: () -> Void

  init(
    transcribeChunk: @escaping (URL) async throws -> String,
    cleanUpAudioFile: @escaping (URL) -> Void,
    appStateIsRecordingMeeting: @escaping () -> Bool,
    onFinished: @escaping () -> Void
  ) {
    self.transcribeChunk = transcribeChunk
    self.cleanUpAudioFile = cleanUpAudioFile
    self.appStateIsRecordingMeeting = appStateIsRecordingMeeting
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
  /// ID of the last chunk included in the rolling summary. Robust against chunk trimming.
  private var lastSummarizedChunkID: UUID? = nil
  /// When non-nil, `finish()` renames the transcript file to this stem (or timestamp-suffix) before ending.
  private var preferredName: String?
  /// Set to true after showing the rate-limit popup once this session so we don't spam.
  private var didShowRateLimitAlert: Bool = false
  /// Consecutive rolling-summary failures (e.g. sustained Gemini 503). Reset to 0 on any success.
  private var consecutiveSummaryFailures: Int = 0
  /// True once the rolling-summary circuit-breaker has tripped: we stop scheduling further rolling
  /// updates for this session (the final summary is still attempted at end). Prevents hammering an
  /// unavailable model dozens of times during one meeting.
  private var summaryCircuitOpen: Bool = false
  /// Set to true after showing the "summary unavailable" popup once this session so we don't spam.
  private var didShowSummaryFailureAlert: Bool = false
  /// Consecutive rolling-summary failures before the circuit-breaker opens and we notify the user.
  private let summaryFailureThreshold = 3
  /// Single-flight guard: true while a rolling-summary API call is in flight. A summary update can
  /// take 60–100s+ on a long meeting, but chunks arrive every ~45s — without this guard each
  /// threshold fired a fresh overlapping call, piling up concurrent requests that raced on
  /// `lastSummarizedChunkID`. When set, an on-demand refresh request is dropped: the in-flight call
  /// will already fold in every chunk accumulated so far.
  private var summaryUpdateInFlight: Bool = false
  /// Bumped on every session start. A rolling-summary Task captures the generation it launched under
  /// so a straggler from a previous meeting (its API call can outlive a stop+restart) no-ops instead
  /// of clearing the in-flight flag — or writing summary/chunk state — for the newer session.
  private var sessionGeneration = 0
  /// When true, `finish()` deletes the transcript instead of saving.
  private var discard: Bool = false

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
    let savedInterval = UserDefaults.standard.double(
      forKey: UserDefaultsKeys.liveMeetingChunkInterval)
    let chunkInterval: TimeInterval =
      savedInterval > 0 ? savedInterval : SettingsDefaults.liveMeetingChunkInterval.rawValue

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
    consecutiveSummaryFailures = 0
    summaryCircuitOpen = false
    didShowSummaryFailureAlert = false
    summaryUpdateInFlight = false
    sessionGeneration += 1
    if resuming && !existingChunks.isEmpty {
      LiveMeetingTranscriptStore.shared.resumeSession()
      // Preserve existing summarized state; if nil it falls back to "from start" which is safe.
    } else {
      LiveMeetingTranscriptStore.shared.startSession()
      lastSummarizedChunkID = nil
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
        DebugLogger.log("LIVE-MEETING: Discarded transcript and summary files")
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
    lastSummarizedChunkID = nil
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
    }
  }

  static func formatTimestamp(elapsedSeconds: TimeInterval) -> String {
    let minutes = Int(elapsedSeconds) / 60
    let seconds = Int(elapsedSeconds) % 60
    return String(format: "[%02d:%02d]", minutes, seconds)
  }

  // MARK: - Rolling summary

  /// On-demand rolling summary refresh. Called when a consumer actually needs an up-to-date live
  /// summary — the Summary tab is shown for the active meeting, or the user chats with it — rather
  /// than on a timer. This folds every transcript chunk accumulated since the last summary into one
  /// call, so cost is proportional to how often the user looks, not to meeting length. The
  /// end-of-meeting summary in `finish()` is regenerated from the full transcript and does not
  /// depend on this.
  func refreshRollingSummary() {
    // Only meaningful while a meeting is actively recording (the live store owns the current stem).
    guard appStateIsRecordingMeeting() else { return }

    // Circuit-breaker: after repeated failures (e.g. a sustained model outage) we stop firing
    // rolling updates for the rest of the session instead of retrying for an hour. The
    // end-of-meeting summary is still attempted once in finish().
    guard !summaryCircuitOpen else { return }

    // Single-flight: if a previous update is still running (they can take 60–100s+), don't launch a
    // second concurrent call. The in-flight call already folds in every chunk accumulated so far, and
    // the next on-demand request will pick up anything newer.
    guard !summaryUpdateInFlight else {
      DebugLogger.log(
        "LIVE-MEETING-SUMMARY: previous update still in flight — skipping on-demand refresh")
      return
    }

    let store = LiveMeetingTranscriptStore.shared
    let result = store.chunkTexts(afterID: lastSummarizedChunkID)
    guard !result.text.isEmpty, let newLastID = result.lastID else { return }

    let currentSummary = store.summary
    let newText = result.text
    let previousLastID = lastSummarizedChunkID
    lastSummarizedChunkID = newLastID
    summaryUpdateInFlight = true
    let generation = sessionGeneration

    Task {
      await runRollingSummaryUpdate(
        currentSummary: currentSummary,
        newText: newText,
        previousLastID: previousLastID,
        generation: generation
      )
      await MainActor.run {
        // Ignore a straggler from a previous session — clearing the flag here would defeat the
        // single-flight guard for the meeting that's now running.
        guard generation == self.sessionGeneration else { return }
        self.summaryUpdateInFlight = false
      }
    }
  }

  /// Merges new transcript into the rolling summary (via the selected model's provider) and updates
  /// the store. Call from a Task.
  private func runRollingSummaryUpdate(
    currentSummary: String, newText: String, previousLastID: UUID?, generation: Int
  ) async {
    let model = PromptModel.loadSelectedMeetingSummary()
    guard model.hasRequiredCredential else {
      DebugLogger.logWarning(
        "LIVE-MEETING-SUMMARY: No credential for \(model.rawValue) — skipping rolling summary update")
      return
    }
    do {
      let updated = try await MeetingListService.updateRollingSummary(
        currentSummary: currentSummary, newText: newText, model: model)
      await MainActor.run {
        // A straggler from a previous session must not write into the current meeting's state.
        guard generation == self.sessionGeneration else { return }
        let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        LiveMeetingTranscriptStore.shared.updateSummary(trimmed)
        if let url = self.transcriptURL, !trimmed.isEmpty {
          MeetingListService.shared.saveSummary(trimmed, transcriptFileURL: url)
        }
        self.consecutiveSummaryFailures = 0
        DebugLogger.log("LIVE-MEETING-SUMMARY: Rolling summary updated (\(updated.count) chars)")
      }
    } catch {
      DebugLogger.logError("LIVE-MEETING-SUMMARY: Update failed: \(error.localizedDescription)")
      await MainActor.run {
        guard generation == self.sessionGeneration else { return }
        // Roll back so the next attempt re-summarizes the same range.
        self.lastSummarizedChunkID = previousLastID
        self.consecutiveSummaryFailures += 1
        // Trip the circuit-breaker after sustained failures: stop hammering the model for the
        // rest of the session and tell the user once (the final summary is still attempted at end).
        if self.consecutiveSummaryFailures >= self.summaryFailureThreshold
          && !self.summaryCircuitOpen {
          self.summaryCircuitOpen = true
          DebugLogger.logWarning(
            "LIVE-MEETING-SUMMARY: circuit-breaker tripped after \(self.consecutiveSummaryFailures) consecutive failures — pausing live summary for this session"
          )
          if !self.didShowSummaryFailureAlert {
            self.didShowSummaryFailureAlert = true
            PopupNotificationWindow.showError(
              "The live summary couldn't be updated (the summary model is unavailable). Recording continues normally; a summary will be generated when the meeting ends.",
              title: "Live Meeting – Summary Paused"
            )
          }
        }
      }
    }
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
      return
    }

    if isFinal {
      awaitingFinalChunk = false
    }

    if isSilent {
      DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent audio)")
      cleanUpAudioFile(audioURL)
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
            self.appendToTranscript(trimmedText, chunkStartTime: startTime)
            // No rolling-summary call here: the live summary is refreshed on demand (Summary tab
            // shown / live meeting chatted), so we don't pay for updates nobody looks at.
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
