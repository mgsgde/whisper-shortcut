import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The pill has a fixed width per phase, so its status word must stay short, and each mode must
/// say which mode it is — the old pill read "Listening"/"Transcribing" for every flow.
@Suite("Recording pill labels")
struct PillLabelTests {

  @Test("Recording modes are distinguishable and short")
  func recordingLabels() {
    #expect(AppState.RecordingMode.transcription.pillLabel == "Listening")
    #expect(AppState.RecordingMode.prompt.pillLabel != AppState.RecordingMode.transcription.pillLabel)
    #expect(AppState.RecordingMode.voiceFeedback.pillLabel != AppState.RecordingMode.transcription.pillLabel)
    for mode: AppState.RecordingMode in [.transcription, .prompt, .liveMeeting, .voiceFeedback] {
      #expect(mode.pillLabel.count <= 12)
    }
  }

  @Test("Processing labels follow the work, including chunked TTS")
  func processingLabels() {
    #expect(AppState.ProcessingMode.transcribing.pillLabel == "Transcribing")
    #expect(AppState.ProcessingMode.prompting.pillLabel == "Thinking")
    #expect(AppState.ProcessingMode.ttsProcessing.pillLabel == "Preparing")
    #expect(AppState.ProcessingMode.merging(context: .tts).pillLabel == "Preparing")
    #expect(AppState.ProcessingMode.merging(context: .transcription).pillLabel == "Transcribing")
  }

  @Test("Every chat provider has a picker section title")
  func providerSectionTitles() {
    for provider in ChatModelProvider.allCases {
      #expect(!provider.pickerSectionTitle.isEmpty)
    }
    #expect(ChatModelProvider.openai.pickerSectionTitle == "GPT")
  }
}
