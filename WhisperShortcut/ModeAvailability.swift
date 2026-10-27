import Foundation

/// One decision per mode: what does a press of its shortcut (or its menu row) do right now?
/// The hotkey handlers, the status-menu titles and the central Stop row all read this, so they
/// cannot drift apart. Pure value logic on purpose — no `#if` and no singletons — so tests can
/// pin every branch. Branch order mirrors the handlers it replaced.

/// A live-meeting segment: Dictate or Dictate Prompt running in parallel with the meeting.
enum MeetingSegment: Equatable { case dictation, prompt }

enum ModeAction: CaseIterable, Equatable {
  case dictate, dictatePrompt, readAloudSelection, readAloudChat, liveMeeting
}

enum CredentialNeed: Equatable { case transcription, prompt, improvement, readAloud, meeting }

enum BlockReason: Equatable {
  /// Info popup "Busy – wait for the current run to finish." / "Busy".
  case busy
  case missingCredential(CredentialNeed)
  /// Error `OfflineMode.blockedMessageForReadAloud` / "Read Aloud".
  case offlineModeReadAloud
  /// Info "Finish the current recording or Read Aloud first, …" / "Meeting Not Started".
  case meetingWhileBusy
}

enum IgnoreReason: Equatable {
  case otherMeetingSegmentActive, liveMeetingActive, otherModeRecording, otherProcessing
}

enum ModeAvailability: Equatable {
  case start, stop, cancelPendingStart, cancelProcessing
  case blocked(BlockReason)
  case ignored(IgnoreReason)
}

struct ModeAvailabilityInput: Equatable {
  var appState: AppState
  var isLiveMeetingActive: Bool
  var activeMeetingSegment: MeetingSegment?
  var pendingMeetingSegment: MeetingSegment?
  var pendingRecordingMode: AppState.RecordingMode?
  var currentJobMode: AppState.RecordingMode?
  var isTTSPlaying: Bool
  var isOfflineMode: Bool
  var readAloudUsesSystemVoice: Bool
  var hasTranscriptionCredential: Bool
  var hasPromptCredential: Bool
  var hasImprovementCredential: Bool
  var hasReadAloudCredential: Bool
  var hasMeetingCredential: Bool
}

extension AppState {
  /// True when any transcription pipeline phase is active (single request or chunked).
  var isTranscriptionPipelineProcessing: Bool {
    guard case .processing(let mode) = self, !mode.isTTSContext else { return false }
    switch mode {
    case .transcribing, .splitting, .processingChunks, .merging:
      return true
    case .prompting, .ttsProcessing:
      return false
    }
  }

  /// True when TTS is running in any phase: .ttsProcessing or chunked phases with TTS context.
  var isTTSPipelineProcessing: Bool {
    if case .processing(let mode) = self { return mode.isTTSContext }
    return false
  }
}

enum ModeAvailabilityRules {
  static func availability(_ action: ModeAction, _ i: ModeAvailabilityInput) -> ModeAvailability {
    switch action {
    case .dictate:
      return dictate(i)
    case .dictatePrompt:
      return dictatePrompt(i)
    case .readAloudSelection:
      if let early = readAloudEarly(i) { return early }
      if i.isOfflineMode, !i.readAloudUsesSystemVoice { return .blocked(.offlineModeReadAloud) }
      if i.isLiveMeetingActive { return .ignored(.liveMeetingActive) }
      // DRIFT F3 (fixed): a non-meeting recording owns the microphone; a synthetic ⌘C into the
      // frontmost app would be pointless and the poll would abandon silently afterwards. A start
      // still waiting for the microphone counts too.
      if i.appState.isRecording || i.pendingRecordingMode != nil { return .ignored(.otherModeRecording) }
      if !i.hasReadAloudCredential { return .blocked(.missingCredential(.readAloud)) }
      return .start
    case .readAloudChat:
      // DRIFT F4 — preserved: only the stop / other-processing arms; a recording or meeting does
      // not block Chat Read Aloud (it overwrites `appState`).
      return readAloudEarly(i) ?? .start
    case .liveMeeting:
      if i.isLiveMeetingActive { return .stop }
      if !i.hasMeetingCredential { return .blocked(.missingCredential(.meeting)) }
      if i.appState.isBusy { return .blocked(.meetingWhileBusy) }
      return .start
    }
  }

  /// Rows whose title flips to "Stop …" are the ones with `availability == .stop`. The central
  /// Stop row shows while something is active and no present row already says Stop.
  static func showsCentralStop(_ i: ModeAvailabilityInput, presentRows: [ModeAction]) -> Bool {
    let anythingActive = i.appState.isBusy || i.isLiveMeetingActive || i.isTTSPlaying
    guard anythingActive else { return false }
    return !presentRows.contains { availability($0, i) == .stop }
  }

  // MARK: - Per mode

  /// Stop / ignore arms shared by both Read Aloud entry points.
  private static func readAloudEarly(_ i: ModeAvailabilityInput) -> ModeAvailability? {
    if i.appState.isTTSPipelineProcessing || i.isTTSPlaying { return .stop }
    if case .processing = i.appState { return .ignored(.otherProcessing) }
    return nil
  }

  /// Shared by Dictate and Dictate Prompt: a press with nothing recording or processing.
  private static func startOrBlock(
    _ i: ModeAvailabilityInput, hasCredential: Bool, need: CredentialNeed
  ) -> ModeAvailability {
    if i.pendingRecordingMode != nil { return .cancelPendingStart }
    if i.appState.isBusy { return .blocked(.busy) }
    return hasCredential ? .start : .blocked(.missingCredential(need))
  }

  private static func meetingSegmentArm(
    _ i: ModeAvailabilityInput, own: MeetingSegment, hasCredential: Bool, need: CredentialNeed
  ) -> ModeAvailability {
    if i.activeMeetingSegment == own || i.pendingMeetingSegment == own { return .stop }
    if i.activeMeetingSegment != nil || i.pendingMeetingSegment != nil {
      return .ignored(.otherMeetingSegmentActive)
    }
    return hasCredential ? .start : .blocked(.missingCredential(need))
  }

  private static func dictate(_ i: ModeAvailabilityInput) -> ModeAvailability {
    if i.isLiveMeetingActive {
      return meetingSegmentArm(
        i, own: .dictation, hasCredential: i.hasTranscriptionCredential, need: .transcription)
    }
    // A long Dictate Prompt also runs through the chunk phases; Dictate must not cancel it.
    if i.appState.isTranscriptionPipelineProcessing, i.currentJobMode != .prompt {
      return .cancelProcessing
    }
    switch i.appState.recordingMode {
    case .transcription: return .stop
    case .none:
      return startOrBlock(i, hasCredential: i.hasTranscriptionCredential, need: .transcription)
    default: return .ignored(.otherModeRecording)
    }
  }

  private static func dictatePrompt(_ i: ModeAvailabilityInput) -> ModeAvailability {
    if i.isLiveMeetingActive {
      return meetingSegmentArm(
        i, own: .prompt, hasCredential: i.hasPromptCredential, need: .prompt)
    }
    if case .processing(.prompting) = i.appState { return .cancelProcessing }
    if i.appState.isTranscriptionPipelineProcessing, i.currentJobMode == .prompt {
      return .cancelProcessing
    }
    switch i.appState.recordingMode {
    case .prompt: return .stop
    case .none:
      return startOrBlock(i, hasCredential: i.hasPromptCredential, need: .prompt)
    default: return .ignored(.otherModeRecording)
    }
  }
}
