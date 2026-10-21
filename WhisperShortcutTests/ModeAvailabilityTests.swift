import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the one decision behind the hotkeys, the status-menu titles and the central Stop row.
@Suite("Mode availability")
struct ModeAvailabilityTests {
  private func input(
    _ state: AppState = .idle,
    meeting: Bool = false,
    active: MeetingSegment? = nil,
    pending: MeetingSegment? = nil,
    pendingMode: AppState.RecordingMode? = nil,
    jobMode: AppState.RecordingMode? = nil,
    playing: Bool = false,
    offline: Bool = false,
    systemVoice: Bool = false,
    transcription: Bool = true,
    prompt: Bool = true,
    improvement: Bool = true,
    readAloud: Bool = true,
    meetingCredential: Bool = true
  ) -> ModeAvailabilityInput {
    ModeAvailabilityInput(
      appState: state, isLiveMeetingActive: meeting, activeMeetingSegment: active,
      pendingMeetingSegment: pending, pendingRecordingMode: pendingMode,
      currentJobMode: jobMode, isTTSPlaying: playing, isOfflineMode: offline,
      readAloudUsesSystemVoice: systemVoice, hasTranscriptionCredential: transcription,
      hasPromptCredential: prompt, hasImprovementCredential: improvement,
      hasReadAloudCredential: readAloud, hasMeetingCredential: meetingCredential)
  }

  private func a(_ action: ModeAction, _ i: ModeAvailabilityInput) -> ModeAvailability {
    ModeAvailabilityRules.availability(action, i)
  }

  @Test("Dictate outside a meeting")
  func dictate() {
    #expect(a(.dictate, input()) == .start)
    #expect(a(.dictate, input(transcription: false)) == .blocked(.missingCredential(.transcription)))
    #expect(a(.dictate, input(.speaking)) == .start)
    #expect(a(.dictate, input(.feedback(.success("x")))) == .start)
    #expect(a(.dictate, input(.recording(.transcription))) == .stop)
    #expect(a(.dictate, input(.recording(.prompt))) == .ignored(.otherModeRecording))
    #expect(a(.dictate, input(.recording(.voiceFeedback))) == .ignored(.otherModeRecording))
    #expect(a(.dictate, input(.processing(.transcribing), jobMode: .transcription)) == .cancelProcessing)
    #expect(a(.dictate, input(.processing(.transcribing))) == .cancelProcessing)
    // A long Dictate Prompt in the chunk phases is not cancelled by Dictate.
    #expect(a(.dictate, input(.processing(.splitting(context: .transcription)), jobMode: .prompt)) == .blocked(.busy))
    #expect(a(.dictate, input(.processing(.ttsProcessing))) == .blocked(.busy))
    #expect(a(.dictate, input(pendingMode: .prompt)) == .cancelPendingStart)
  }

  @Test("Dictate as a live-meeting segment")
  func dictateInMeeting() {
    let state = AppState.recording(.liveMeeting)
    #expect(a(.dictate, input(state, meeting: true)) == .start)
    #expect(a(.dictate, input(state, meeting: true, transcription: false)) == .blocked(.missingCredential(.transcription)))
    #expect(a(.dictate, input(state, meeting: true, active: .dictation)) == .stop)
    #expect(a(.dictate, input(state, meeting: true, pending: .dictation)) == .stop)
    #expect(a(.dictate, input(state, meeting: true, active: .prompt)) == .ignored(.otherMeetingSegmentActive))
  }

  @Test("Dictate Prompt")
  func dictatePrompt() {
    #expect(a(.dictatePrompt, input()) == .start)
    #expect(a(.dictatePrompt, input(.processing(.prompting))) == .cancelProcessing)
    #expect(a(.dictatePrompt, input(.processing(.merging(context: .transcription)), jobMode: .prompt)) == .cancelProcessing)
    #expect(a(.dictatePrompt, input(.processing(.transcribing), jobMode: .transcription)) == .blocked(.busy))
    #expect(a(.dictatePrompt, input(.recording(.prompt))) == .stop)
    #expect(a(.dictatePrompt, input(prompt: false)) == .blocked(.missingCredential(.prompt)))
    #expect(a(.dictatePrompt, input(.recording(.transcription))) == .ignored(.otherModeRecording))
    #expect(a(.dictatePrompt, input(pendingMode: .transcription)) == .cancelPendingStart)
    #expect(a(.dictatePrompt, input(.recording(.liveMeeting), meeting: true, active: .dictation)) == .ignored(.otherMeetingSegmentActive))
    #expect(a(.dictatePrompt, input(.recording(.liveMeeting), meeting: true, active: .prompt)) == .stop)
  }

  @Test("Voice Feedback")
  func voiceFeedback() {
    #expect(a(.voiceFeedback, input()) == .start)
    #expect(a(.voiceFeedback, input(.recording(.liveMeeting), meeting: true)) == .ignored(.liveMeetingActive))
    #expect(a(.voiceFeedback, input(.processing(.contextEditing))) == .cancelProcessing)
    #expect(a(.voiceFeedback, input(.recording(.voiceFeedback))) == .stop)
    #expect(a(.voiceFeedback, input(.recording(.transcription))) == .ignored(.otherModeRecording))
    #expect(a(.voiceFeedback, input(pendingMode: .transcription)) == .cancelPendingStart)
    #expect(a(.voiceFeedback, input(improvement: false)) == .blocked(.missingCredential(.improvement)))
    #expect(a(.voiceFeedback, input(transcription: false)) == .blocked(.missingCredential(.transcription)))
    // F2 — fixed: a busy app answers "Busy", not with the transcription credential message.
    #expect(a(.voiceFeedback, input(.processing(.transcribing))) == .blocked(.busy))
    #expect(a(.voiceFeedback, input(.processing(.transcribing), transcription: false)) == .blocked(.busy))
  }

  @Test("Read Aloud on a selection")
  func readAloudSelection() {
    #expect(a(.readAloudSelection, input()) == .start)
    #expect(a(.readAloudSelection, input(.processing(.ttsProcessing))) == .stop)
    #expect(a(.readAloudSelection, input(.processing(.splitting(context: .tts)))) == .stop)
    #expect(a(.readAloudSelection, input(playing: true)) == .stop)
    #expect(a(.readAloudSelection, input(.processing(.transcribing))) == .ignored(.otherProcessing))
    #expect(a(.readAloudSelection, input(offline: true)) == .blocked(.offlineModeReadAloud))
    #expect(a(.readAloudSelection, input(offline: true, systemVoice: true)) == .start)
    // Order: the Offline Mode popup comes before the silent live-meeting ignore.
    #expect(a(.readAloudSelection, input(.recording(.liveMeeting), meeting: true, offline: true)) == .blocked(.offlineModeReadAloud))
    #expect(a(.readAloudSelection, input(.recording(.liveMeeting), meeting: true)) == .ignored(.liveMeetingActive))
    #expect(a(.readAloudSelection, input(readAloud: false)) == .blocked(.missingCredential(.readAloud)))
    // F3 — fixed: no synthetic ⌘C while another (non-meeting) recording runs.
    #expect(a(.readAloudSelection, input(.recording(.transcription))) == .ignored(.otherModeRecording))
  }

  @Test("Read Aloud from Chat")
  func readAloudChat() {
    // DRIFT F4 — preserved: Chat Read Aloud only refuses a processing run, so it starts during a
    // meeting recording (and overwrites `appState`).
    #expect(a(.readAloudChat, input(.recording(.liveMeeting), meeting: true)) == .start)
    #expect(a(.readAloudChat, input(.processing(.prompting))) == .ignored(.otherProcessing))
    #expect(a(.readAloudChat, input(.processing(.ttsProcessing))) == .stop)
  }

  @Test("Live meeting")
  func liveMeeting() {
    #expect(a(.liveMeeting, input(.recording(.liveMeeting), meeting: true)) == .stop)
    #expect(a(.liveMeeting, input(.processing(.transcribing), meetingCredential: false)) == .blocked(.missingCredential(.meeting)))
    #expect(a(.liveMeeting, input(.processing(.transcribing))) == .blocked(.meetingWhileBusy))
    #expect(a(.liveMeeting, input()) == .start)
  }

  @Test("Central Stop row")
  func centralStop() {
    let rows: [ModeAction] = [.dictate, .dictatePrompt, .readAloudSelection, .voiceFeedback]
    func show(_ i: ModeAvailabilityInput) -> Bool {
      ModeAvailabilityRules.showsCentralStop(i, presentRows: rows)
    }
    #expect(show(input(.processing(.transcribing))))
    #expect(!show(input(.recording(.transcription))))
    #expect(show(input(.recording(.liveMeeting), meeting: true)))
    #expect(!show(input(.recording(.liveMeeting), meeting: true, active: .dictation)))
    #expect(!show(input(playing: true)))
    // Voice Feedback reads "Stop Voice Feedback" while recording, so the central Stop hides.
    #expect(!show(input(.recording(.voiceFeedback))))
    #expect(show(input(.processing(.contextEditing))))
    #expect(!show(input()))
  }
}
