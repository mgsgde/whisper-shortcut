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

  // MARK: - Selection source

  /// The App Store build reads the Dictate Prompt selection off a screenshot. A local model is
  /// text-only, so it received the "edit the highlighted region" system prompt with no image and
  /// — because screenshot mode skips the clipboard — no text either, and duly "edited" the voice
  /// instruction. The selection source has to follow the model, not the build.
  @Test("A local model never takes its selection from a screenshot")
  func localModelAlwaysUsesClipboard() {
    #expect(PromptModel.localModel.dictatePromptUsesScreenshotSelection == false)
  }

  /// The other side of the same rule: models that *can* see an image still follow the build, so
  /// this fix does not quietly turn the App Store build's screenshot flow off for everyone.
  @Test("Image-capable models still follow the build's selection mode")
  func geminiFollowsBuildSelectionMode() {
    #expect(
      PromptModel.gemini31FlashLite.dictatePromptUsesScreenshotSelection
        == AppConstants.dictatePromptUsesScreenshotSelection)
  }

  /// The system prompt is what actually reaches the model, so pin that too. Not by keyword — the
  /// clipboard prompt mentions a screenshot legitimately, as optional context for *how* to edit —
  /// but by which of the two prompts is chosen: only the screenshot one says the text to edit IS
  /// the highlighted region, and that is the instruction a local model cannot satisfy.
  @Test("The clipboard selection does not get the screenshot-selection system prompt")
  func clipboardSelectionGetsTheClipboardSystemPrompt() {
    let screenshotPrompt =
      AppConstants.dictatePromptScreenshotSelectionSystemPrompt + AppConstants.promptModeOutputRule

    let forClipboard = SpeechService.buildDictatePromptSystemPrompt(
      logPrefix: "TEST", usesScreenshotSelection: false)
    let forScreenshot = SpeechService.buildDictatePromptSystemPrompt(
      logPrefix: "TEST", usesScreenshotSelection: true)

    #expect(forClipboard != screenshotPrompt)
    #expect(forScreenshot == screenshotPrompt)
  }

  // MARK: - Request body

  /// Ollama is the default endpoint and does not read `chat_template_kwargs`; its documented
  /// switch is `reasoning_effort`. Sending only the former left thinking on for exactly the
  /// setup most users have, which costs seconds of first-token latency.
  @Test("Thinking is switched off in both spellings the servers understand")
  func sendsBothThinkingSwitches() {
    let body = LocalLLMChatProvider.requestBody(
      model: "llama3.2", messages: [], stream: true, maxTokens: 4096)

    #expect(body["reasoning_effort"] as? String == "none")
    #expect((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
  }

  /// The prewarm exists to prime the server's prompt cache, and a cache hit needs the same
  /// rendered prefix both times. Any field that steers chat-template rendering must therefore be
  /// identical between the warm-up body and the real one — only transport-level fields may differ.
  @Test("Prewarm and real request agree on everything that shapes the prompt")
  func prewarmBodyMatchesRealBody() {
    let messages: [[String: Any]] = [["role": "system", "content": "You edit text."]]
    let real = LocalLLMChatProvider.requestBody(
      model: "llama3.2", messages: messages, stream: true, maxTokens: 4096)
    let warm = LocalLLMChatProvider.requestBody(
      model: "llama3.2", messages: messages, stream: false, maxTokens: 1)

    #expect(real["reasoning_effort"] as? String == warm["reasoning_effort"] as? String)
    #expect(
      (real["chat_template_kwargs"] as? [String: Bool])
        == (warm["chat_template_kwargs"] as? [String: Bool]))
    #expect(real["model"] as? String == warm["model"] as? String)
    // The two that are allowed to differ, so a future field lands in the block above by default.
    #expect(real["stream"] as? Bool == true)
    #expect(warm["stream"] as? Bool == false)
  }
}
