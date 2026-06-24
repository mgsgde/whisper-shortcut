import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Live roundtrip against every LLM provider. The cheapest model in each
/// family is asked to reply with a single word; the test passes if any
/// non-empty text comes back. Catches: broken auth, request-shape drift,
/// structured-output parsing regressions, and silent provider API changes —
/// the failure modes that otherwise only surface in production.
///
/// A test is skipped when its provider's key is missing, so a single-provider
/// user doesn't see red for providers they don't use. Keys resolve from
/// environment variables first (`WHISPERSHORTCUT_GOOGLE_API_KEY`/`GOOGLE_API_KEY`,
/// `WHISPERSHORTCUT_XAI_API_KEY`/`XAI_API_KEY`, `WHISPERSHORTCUT_OPENAI_API_KEY`/
/// `OPENAI_API_KEY`), set in the test plan's Environment Variables or on the
/// xcodebuild command line, falling back to the Keychain — env injection avoids
/// the macOS Keychain ACL prompt that the `xctest` binary would otherwise
/// trigger on every run.
@Suite("LLM provider roundtrip (live)")
struct LLMProviderRoundtripTests {

    private static let prompt = "Reply with exactly the word: pong"

    @Test(
        "Gemini provider returns a non-empty reply",
        .enabled(if: KeychainManager.shared.hasValidGoogleAPIKey(),
                 "No Google API key (env WHISPERSHORTCUT_GOOGLE_API_KEY or Keychain)")
    )
    func gemini() async throws {
        let reply = try await GeminiChatProvider.shared.generateText(
            model: PromptModel.gemini25FlashLite.rawValue,
            prompt: Self.prompt
        )
        #expect(!reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(
        "OpenAI provider returns a non-empty reply",
        .enabled(if: KeychainManager.shared.hasValidOpenAIAPIKey(),
                 "No OpenAI API key (env WHISPERSHORTCUT_OPENAI_API_KEY or Keychain)")
    )
    func openai() async throws {
        let reply = try await OpenAIChatProvider.shared.generateText(
            model: PromptModel.openaiGPT5Mini.rawValue,
            prompt: Self.prompt
        )
        #expect(!reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(
        "Grok provider returns a non-empty reply",
        .enabled(if: KeychainManager.shared.hasValidXAIAPIKey(),
                 "No xAI API key (env WHISPERSHORTCUT_XAI_API_KEY or Keychain)")
    )
    func grok() async throws {
        let reply = try await GrokChatProvider.shared.generateText(
            model: PromptModel.grok4.rawValue,
            prompt: Self.prompt
        )
        #expect(!reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
