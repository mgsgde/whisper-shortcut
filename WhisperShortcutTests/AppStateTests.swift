import Testing
@testable import WhisperShortcut_AppStore

@Suite("AppState transitions")
struct AppStateTests {

  @Test(
    "Busy states refuse a second startRecording, and stopRecording is a no-op outside recording",
    arguments: [
      ("idle", "stopRecording is a no-op outside recording"),
      ("recording", "recording refuses a second start"),
      ("processing", "processing refuses a second start"),
    ])
  func busyRefusesSecondStart(state: String, note: String) {
    switch state {
    case "idle":
      #expect(AppState.idle.stopRecording() == .idle, "\(note)")
    case "recording":
      let recording = AppState.idle.startRecording(.prompt)
      #expect(recording.startRecording(.transcription) == recording, "\(note)")
    default:
      let processing = AppState.idle.startRecording(.prompt).stopRecording()
      #expect(processing.startRecording(.transcription) == processing, "\(note)")
    }
  }

  @Test("Speaking is not busy, so a new recording can start over playback")
  func speakingIsNotBusy() {
    let speaking = AppState.speaking
    #expect(!speaking.isBusy)
    #expect(speaking.startRecording(.transcription) == .recording(.transcription))
    #expect(speaking.canStartTranscription(hasAPIKey: true))
    #expect(speaking.signalPhase == "speaking")
    #expect(speaking.icon == "🔊")
  }

  @Test("Feedback is not busy and finish returns to idle")
  func feedbackIsTransient() {
    let success = AppState.idle.showSuccess("Pasted")
    #expect(success == .feedback(.success("Pasted")))
    #expect(!success.isBusy)
    #expect(success.finish() == .idle)
    #expect(AppState.idle.showError("Nope") == .feedback(.error("Nope")))
    #expect(AppState.feedback(.error("x")).signalPhase == "feedback")
  }

  @Test("stopRecording maps each recording mode onto the matching processing mode")
  func stopRecordingModes() {
    #expect(
      AppState.idle.startRecording(.transcription).stopRecording()
        == .processing(.transcribing))
    #expect(
      AppState.idle.startRecording(.prompt).stopRecording()
        == .processing(.prompting))
    #expect(
      AppState.idle.startRecording(.liveMeeting).stopRecording()
        == .processing(.transcribing))
  }

  @Test("Chunk processing reports counts, TTS context, and telemetry phase")
  func chunkProcessingProperties() {
    let statuses: [ChunkStatus] = [.completed, .active, .pending, .failed]
    let chunks = AppState.processing(.processingChunks(statuses: statuses, context: .transcription))
    #expect(chunks.isBusy)
    #expect(chunks.isProcessing)
    #expect(chunks.isNonTTSProcessing)
    #expect(!chunks.isRecording)
    #expect(chunks.signalPhase == "processingChunks-4")
    if case .processing(let mode) = chunks {
      #expect(mode.completedCount == 1)
      #expect(mode.activeCount == 1)
      #expect(mode.totalCount == 4)
      #expect(!mode.isTTSContext)
      #expect(mode.chunkContext == .transcription)
    }

    let ttsSplit = AppState.processing(.splitting(context: .tts))
    #expect(ttsSplit.isBusy)
    #expect(!ttsSplit.isNonTTSProcessing)
    #expect(ttsSplit.signalPhase == "splitting")
    if case .processing(let mode) = ttsSplit {
      #expect(mode.isTTSContext)
      #expect(mode.chunkContext == .tts)
      #expect(mode.icon == "✂️")
    }

    let merging = AppState.processing(.merging(context: .transcription))
    #expect(merging.signalPhase == "merging")
    #expect(AppState.processing(.prompting).signalPhase == "prompting")
    #expect(AppState.processing(.ttsProcessing).signalPhase == "ttsProcessing")
    #expect(AppState.recording(.liveMeeting).signalPhase == "recording-liveMeeting")
  }

  @Test("Menu enablement requires a key or an offline model and a free state")
  func menuEnablement() {
    #expect(AppState.idle.canStartTranscription(hasAPIKey: true))
    #expect(AppState.idle.canStartPrompting(hasAPIKey: false, hasOfflineModel: true))
    #expect(!AppState.idle.canStartTranscription(hasAPIKey: false, hasOfflineModel: false))
    #expect(!AppState.processing(.transcribing).canStartTranscription(hasAPIKey: true))
    #expect(!AppState.idle.canStopRecording)
    #expect(AppState.recording(.transcription).canStopRecording)
  }

  @Test("Only processing states blink; only idle uses the template symbol")
  func blinkAndSymbol() {
    #expect(!AppState.idle.shouldBlink)
    #expect(AppState.processing(.transcribing).shouldBlink)
    #expect(AppState.idle.symbolName == "mic.fill")
    #expect(AppState.recording(.transcription).symbolName == nil)
    #expect(AppState.speaking.symbolName == nil)
  }
}
