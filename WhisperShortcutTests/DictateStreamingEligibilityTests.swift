import Testing
@testable import WhisperShortcut_AppStore

/// The gate that decides whether a Dictate recording transcribes its chunks while the user is
/// still speaking (`plans/active/streaming-dictate.md`). Slice 4 admitted offline Whisper here,
/// and the interesting cases are the ones that must *not* stream: a model whose weights are not
/// on disk, and a self-hosted endpoint.
@Suite("Streaming Dictate eligibility")
struct DictateStreamingEligibilityTests {

  @Test("A downloaded on-device Whisper streams")
  func downloadedOfflineModelStreams() {
    for model in TranscriptionModel.allCases where model.isOffline {
      #expect(
        DictateStreamingSession.isEligible(
          model: model, hasCredential: false, offlineModelDownloaded: true),
        "\(model.rawValue) should stream once its weights are on disk")
    }
  }

  /// The load-bearing half of the offline gate: an in-flight chunk must never be what starts a
  /// multi-gigabyte download, mid-recording, behind the user's back.
  @Test("An on-device Whisper that is not downloaded does not stream")
  func undownloadedOfflineModelDoesNotStream() {
    for model in TranscriptionModel.allCases where model.isOffline {
      #expect(
        !DictateStreamingSession.isEligible(
          model: model, hasCredential: false, offlineModelDownloaded: false),
        "\(model.rawValue) must not stream while its weights are missing")
    }
    // A credential is irrelevant to the offline path and must not smuggle it past the check.
    #expect(
      !DictateStreamingSession.isEligible(
        model: .whisperLargeTurbo, hasCredential: true, offlineModelDownloaded: false))
  }

  @Test("Cloud STT streams only with a credential")
  func cloudModelsNeedCredential() {
    for model in TranscriptionModel.allCases where model.isGemini || model.isOpenAI || model.isXAI {
      #expect(
        DictateStreamingSession.isEligible(
          model: model, hasCredential: true, offlineModelDownloaded: false),
        "\(model.rawValue) should stream with a credential")
      #expect(
        !DictateStreamingSession.isEligible(
          model: model, hasCredential: false, offlineModelDownloaded: false),
        "\(model.rawValue) must not stream without a credential")
    }
  }

  /// Unknown latency and rate-limit semantics — these keep the single-shot path, credential or not.
  @Test("Self-hosted and OpenRouter endpoints never stream")
  func selfHostedDoesNotStream() {
    for model: TranscriptionModel in [.selfHostedTranscription, .openRouterTranscription] {
      #expect(
        !DictateStreamingSession.isEligible(
          model: model, hasCredential: true, offlineModelDownloaded: true),
        "\(model.rawValue) must keep the single-shot path")
    }
  }
}
