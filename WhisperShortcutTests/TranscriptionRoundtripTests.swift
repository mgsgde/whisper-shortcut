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


    /// Runs a live transcription and asserts a non-empty reply, but treats a provider quota or
    /// rate-limit answer as "not run" rather than a failure.
    ///
    /// These four tests hit real APIs, so a 429 says something about the account's billing window,
    /// never about the code. Failing on it makes the suite non-deterministic and — because
    /// `/release` gates on a green suite — lets an exhausted free-tier quota block a release that
    /// has nothing wrong with it. That is exactly what happened while these tests were written.
    private static func expectTranscript(
        _ model: TranscriptionModel,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        do {
            let text = try await SpeechService().transcribe(
                audioURL: Self.sampleAudioURL, preferredModel: model)
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(label) returned an empty transcript", sourceLocation: sourceLocation)
        } catch let error as TranscriptionError {
            switch error {
            case .rateLimited, .quotaExceeded, .billingRequired:
                print("SKIP: \(label) roundtrip — provider quota/rate limit (\(error)), not a code failure")
            default:
                throw error
            }
        }
    }

    @Test(
        "OpenAI transcription returns a non-empty reply",
        .enabled(if: KeychainManager.shared.hasNonEmpty(.openAI),
                 "No OpenAI API key (env WHISPERSHORTCUT_OPENAI_API_KEY or Keychain)")
    )
    func openai() async throws {
        try await Self.expectTranscript(.openAIGPT4oMiniTranscribe, "OpenAI")
    }

    @Test(
        "OpenAI GPT Transcribe returns a non-empty reply",
        .enabled(if: KeychainManager.shared.hasNonEmpty(.openAI),
                 "No OpenAI API key (env WHISPERSHORTCUT_OPENAI_API_KEY or Keychain)")
    )
    func openAIGPTTranscribe() async throws {
        // Separate from the gpt-4o roundtrip above because the multipart body differs: this model
        // takes the glossary through repeated `keywords` parts and gets no `prompt` at all, and
        // sending a field it rejects is a hard 400 (`keywords` on gpt-4o-transcribe already is).
        try await Self.expectTranscript(.openAIGPTTranscribe, "OpenAI GPT Transcribe")
    }

    @Test(
        "Grok transcription returns a non-empty reply",
        .enabled(if: KeychainManager.shared.hasNonEmpty(.xai),
                 "No xAI API key (env WHISPERSHORTCUT_XAI_API_KEY or Keychain)")
    )
    func grok() async throws {
        try await Self.expectTranscript(.xaiTranscribe, "Grok")
    }

    @Test(
        "Gemini transcription returns a non-empty reply",
        .enabled(if: GeminiCredentialProvider.shared.hasCredential(),
                 "No Google credential (env WHISPERSHORTCUT_GOOGLE_API_KEY or Keychain)")
    )
    func gemini() async throws {
        // Track the shipped default so this roundtrip always exercises the model users actually
        // dictate with (past audio-payload bugs passed on one Gemini tier and failed on another).
        try await Self.expectTranscript(SettingsDefaults.selectedTranscriptionModel, "Gemini")
    }

    @Test(
        "OpenRouter transcription returns a non-empty reply",
        .enabled(if: KeychainManager.shared.hasNonEmpty(.openRouter),
                 "No OpenRouter API key (env WHISPERSHORTCUT_OPENROUTER_API_KEY or Keychain)")
    )
    func openRouter() async throws {
        // The one provider here that is NOT a transcription endpoint: OpenRouter takes audio as an
        // `input_audio` part on a chat completion, so this roundtrip guards a request shape nothing
        // else in the suite covers — and one that fails as a 400/402 rather than a bad transcript.
        try await Self.expectTranscript(.openRouterTranscription, "OpenRouter")
    }
}
