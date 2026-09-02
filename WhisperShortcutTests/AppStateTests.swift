import Testing
@testable import WhisperShortcut_AppStore

@Suite("AppState transitions")
struct AppStateTests {

  @Test("Idle can start recording and stop into processing")
  func idleToRecordingToProcessing() {
    var state = AppState.idle
    state = state.startRecording(.transcription)
    #expect(state == .recording(.transcription))
    state = state.stopRecording()
    #expect(state == .processing(.transcribing))
    state = state.finish()
    #expect(state == .idle)
  }

  @Test("Busy states refuse a second startRecording")
  func busyRefusesSecondStart() {
    let recording = AppState.idle.startRecording(.prompt)
    #expect(recording.startRecording(.transcription) == recording)
    let processing = recording.stopRecording()
    #expect(processing.startRecording(.transcription) == processing)
  }

  @Test("stopRecording is a no-op outside recording")
  func stopFromIdleIsNoOp() {
    #expect(AppState.idle.stopRecording() == .idle)
  }

  @Test("Voice feedback records into context editing")
  func voiceFeedbackProcessingMode() {
    let state = AppState.idle.startRecording(.voiceFeedback).stopRecording()
    #expect(state == .processing(.contextEditing))
  }
}
