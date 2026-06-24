import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Live roundtrip against every cloud speech-to-text provider. Each test
/// hands `SpeechService.transcribe` a tiny WAV fixture and asserts a
/// non-empty reply. Catches: broken multipart encoding (the brittle part
/// of /v1/audio/transcriptions and /v1/stt), key drift, response-shape
/// changes, and Gemini's inline-audio request layout.
///
/// A test is skipped when its provider's key is missing. Keys resolve from
/// environment variables first (`WHISPERSHORTCUT_GOOGLE_API_KEY`/`GOOGLE_API_KEY`,
/// `WHISPERSHORTCUT_XAI_API_KEY`/`XAI_API_KEY`, `WHISPERSHORTCUT_OPENAI_API_KEY`/
/// `OPENAI_API_KEY`), set in the test plan's Environment Variables or on the
/// xcodebuild command line, falling back to the Keychain — env injection avoids
/// the macOS Keychain ACL prompt that the `xctest` binary would otherwise
/// trigger on every run.
@Suite("Transcription provider roundtrip (live)")
struct TranscriptionRoundtripTests {

    /// Anchor class used to resolve the test bundle, so the WAV fixture
    /// (a Copy-Bundle-Resources artifact of the test target) can be located
    /// without depending on Bundle.main, which is the host app.
    private final class TestResourceAnchor {}

    private static var sampleAudioURL: URL {
        guard let url = Bundle(for: TestResourceAnchor.self)
            .url(forResource: "sample", withExtension: "wav") else {
            fatalError("sample.wav missing from test bundle resources")
        }
        return url
    }

    @Test(
        "OpenAI transcription returns a non-empty reply",
        .enabled(if: KeychainManager.shared.hasValidOpenAIAPIKey(),
                 "No OpenAI API key (env WHISPERSHORTCUT_OPENAI_API_KEY or Keychain)")
    )
    func openai() async throws {
        let text = try await SpeechService().transcribe(
            audioURL: Self.sampleAudioURL,
            preferredModel: .openAIGPT4oMiniTranscribe
        )
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(
        "Grok transcription returns a non-empty reply",
        .enabled(if: KeychainManager.shared.hasValidXAIAPIKey(),
                 "No xAI API key (env WHISPERSHORTCUT_XAI_API_KEY or Keychain)")
    )
    func grok() async throws {
        let text = try await SpeechService().transcribe(
            audioURL: Self.sampleAudioURL,
            preferredModel: .xaiTranscribe
        )
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(
        "Gemini transcription returns a non-empty reply",
        .enabled(if: GeminiCredentialProvider.shared.hasCredential(),
                 "No Google credential (env WHISPERSHORTCUT_GOOGLE_API_KEY or Keychain)")
    )
    func gemini() async throws {
        let text = try await SpeechService().transcribe(
            audioURL: Self.sampleAudioURL,
            preferredModel: .gemini25FlashLite
        )
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
