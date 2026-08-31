import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the two ways the local Dictate Prompt path used to hand the user something it shouldn't:
/// a double-appended endpoint path, and a model's private reasoning pasted as the reply.
@Suite("Local LLM")
struct LocalLLMTests {

  // MARK: - Endpoint normalization

  @Test("A bare base URL gets the chat-completions path")
  func appendsPathToBaseURL() {
    #expect(
      LocalLLMPreferences.chatCompletionsURL(forBase: "http://localhost:11434/v1")
        == "http://localhost:11434/v1/chat/completions")
  }

  @Test("A trailing slash doesn't double up")
  func normalizesTrailingSlash() {
    #expect(
      LocalLLMPreferences.chatCompletionsURL(forBase: "http://localhost:11434/v1/")
        == "http://localhost:11434/v1/chat/completions")
  }

  /// The URL Ollama's own docs print, so it is what users paste. Appending to it produced
  /// `.../chat/completions/chat/completions` → 404 → "pull the model first" for a URL typo.
  @Test("A full chat-completions URL is left alone")
  func doesNotAppendTwice() {
    #expect(
      LocalLLMPreferences.chatCompletionsURL(forBase: "http://localhost:11434/v1/chat/completions")
        == "http://localhost:11434/v1/chat/completions")
  }

  // MARK: - Reasoning blocks

  @Test("A leading think block is removed, the answer survives")
  func stripsLeadingThinkBlock() {
    let raw = "<think>The user wants this shorter. Drop the filler.</think>\n\nShip it Friday."
    #expect(LocalLLMChatProvider.strippingReasoningBlocks(raw) == "Ship it Friday.")
  }

  @Test("Several blocks anywhere in the reply are removed")
  func stripsMultipleBlocks() {
    let raw = "<thinking>a</thinking>Ship it <think>hmm</think>Friday."
    #expect(LocalLLMChatProvider.strippingReasoningBlocks(raw) == "Ship it Friday.")
  }

  /// A cancelled stream can end mid-thought. Whatever follows an unclosed opener is reasoning,
  /// never the answer, so it must not reach the clipboard.
  @Test("An unterminated block drops everything after it")
  func dropsUnterminatedBlock() {
    let raw = "Ship it Friday.<think>Actually, wait, maybe"
    #expect(LocalLLMChatProvider.strippingReasoningBlocks(raw) == "Ship it Friday.")
  }

  @Test("Ordinary replies pass through untouched")
  func leavesPlainTextAlone() {
    let raw = "Ship it Friday."
    #expect(LocalLLMChatProvider.strippingReasoningBlocks(raw) == raw)
  }

  /// The common case on a current server: reasoning arrives in `reasoning_content`, which the
  /// stream parser already ignores, so the text carries angle brackets of its own meaning.
  @Test("Unrelated angle brackets are not treated as reasoning")
  func leavesUnrelatedTagsAlone() {
    let raw = "Use <b>bold</b> here."
    #expect(LocalLLMChatProvider.strippingReasoningBlocks(raw) == raw)
  }
}
