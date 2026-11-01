import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// A 404 from the user's own `/audio/transcriptions` used to surface as a generic
/// "try again later". These pin the status mapping without a network round-trip:
/// there is no URLProtocol seam on `transcribeWithSelfHostedEndpoint`.
@Suite("Own-server transcription errors")
struct SelfHostedTranscriptionErrorTests {

  private let missingEndpoint = String(localized: "Your server has no speech-to-text endpoint (HTTP 404 at /audio/transcriptions). Chat can still use it. For dictation, choose another Dictate model, or set a separate Dictate URL under Settings → Dictate → Advanced.")

  @Test("404 and 405 name the missing speech-to-text endpoint")
  func missingEndpointStatuses() {
    for code in [404, 405] {
      #expect(
        SpeechService.selfHostedTranscriptionError(forHTTPStatus: code)
          == .networkError(missingEndpoint))
    }
  }

  @Test("403 is the same invalid-key error as 401")
  func forbiddenIsInvalidKey() {
    #expect(SpeechService.selfHostedTranscriptionError(forHTTPStatus: 403) == .invalidAPIKey)
    #expect(SpeechService.selfHostedTranscriptionError(forHTTPStatus: 401) == .invalidAPIKey)
  }

  @Test("Other statuses stay unmapped so cloud providers keep the shared errors")
  func otherStatusesStayUnmapped() {
    #expect(SpeechService.selfHostedTranscriptionError(forHTTPStatus: 200) == nil)
    #expect(SpeechService.selfHostedTranscriptionError(forHTTPStatus: 422) == nil)
    #expect(SpeechService.selfHostedTranscriptionError(forHTTPStatus: 500) == nil)
  }
}
