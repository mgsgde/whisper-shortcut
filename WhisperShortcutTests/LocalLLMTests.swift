import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the two ways the local Dictate Prompt path used to hand the user something it shouldn't:
/// a double-appended endpoint path, and a model's private reasoning pasted as the reply.
@Suite("Local LLM")
struct LocalLLMTests {

  // MARK: - Endpoint normalization

  @Test("A base URL becomes exactly one chat-completions path", arguments: [
    ("http://localhost:11434/v1", "http://localhost:11434/v1/chat/completions", "bare base URL"),
    ("http://localhost:11434/v1/", "http://localhost:11434/v1/chat/completions", "trailing slash"),
    // The URL Ollama's own docs print, so it is what users paste. Appending to it produced
    // `.../chat/completions/chat/completions` → 404 → "pull the model first" for a URL typo.
    ("http://localhost:11434/v1/chat/completions", "http://localhost:11434/v1/chat/completions",
     "full URL left alone"),
  ])
  func chatCompletionsURL(base: String, expected: String, label: String) {
    #expect(LocalLLMPreferences.chatCompletionsURL(forBase: base) == expected, "\(label)")
  }

  // MARK: - Reasoning blocks

  @Test("Reasoning blocks are removed and ordinary text is left alone", arguments: [
    ("<think>The user wants this shorter. Drop the filler.</think>\n\nShip it Friday.",
     "Ship it Friday.", "leading think block"),
    ("<thinking>a</thinking>Ship it <think>hmm</think>Friday.", "Ship it Friday.", "several blocks"),
    // A cancelled stream can end mid-thought. Whatever follows an unclosed opener is reasoning,
    // never the answer, so it must not reach the clipboard.
    ("Ship it Friday.<think>Actually, wait, maybe", "Ship it Friday.", "unterminated block"),
    ("Ship it Friday.", "Ship it Friday.", "plain text"),
    // The common case on a current server: reasoning arrives in `reasoning_content`, which the
    // stream parser already ignores, so the text carries angle brackets of its own meaning.
    ("Use <b>bold</b> here.", "Use <b>bold</b> here.", "unrelated tags"),
  ])
  func strippingReasoningBlocks(raw: String, expected: String, label: String) {
    #expect(LocalLLMChatProvider.strippingReasoningBlocks(raw) == expected, "\(label)")
  }

  // MARK: - Selection source

  /// The App Store build reads the Dictate Prompt selection off a screenshot. A local model is
  /// text-only, so it received the "edit the highlighted region" system prompt with no image and
  /// — because screenshot mode skips the clipboard — no text either, and duly "edited" the voice
  /// instruction. The selection source has to follow the model, not the build. Image-capable
  /// models still follow the build, so this does not turn the screenshot flow off for everyone.
  @Test("The selection source follows the model, not the build", arguments: [
    (PromptModel.localMLXQwen34BInstruct, false, "MLX uses the clipboard"),
    (.localModel, false, "a local HTTP server uses the clipboard"),
    (.gemini31FlashLite, AppConstants.dictatePromptUsesScreenshotSelection,
     "an image-capable model follows the build"),
  ])
  func selectionSourceFollowsModel(model: PromptModel, usesScreenshot: Bool, label: String) {
    #expect(model.dictatePromptUsesScreenshotSelection == usesScreenshot, "\(label)")
  }

  @Test("A persisted Qwen3 8B selection forwards to the offline 4B default, not to the cloud")
  func retiredQwen38BMigratesToOffline4B() {
    let migrated = PromptModel(rawValue: PromptModel.migrateLegacyPromptRawValue("local-mlx-qwen3-8b"))
    #expect(migrated == .localMLXQwen34BInstruct)
    #expect(migrated?.localMLXModelType != nil)
  }

  @Test("MLX models route through MLXChatProvider")
  func mlxProviderFactory() {
    // `is`, not `===`: `LLMChatProvider` is not class-constrained, so identity comparison does
    // not compile. The claim under test is which provider handles the model anyway, not which
    // instance of it.
    #expect(LLMProviderFactory.provider(for: .localMLXQwen34BInstruct) is MLXChatProvider)
    #expect(LLMProviderFactory.provider(for: .localMLXQwen359B) is MLXChatProvider)
    #expect(LLMProviderFactory.provider(for: .localModel) is LocalLLMChatProvider)
  }

  @Test("Qwen3.5 9B is a Chat-only catalogue entry")
  func qwen359BIsChatOnly() {
    #expect(PromptModel.localMLXQwen359B.supportsDictatePrompt == false)
    #expect(PromptModel.localMLXQwen34BInstruct.supportsDictatePrompt == true)
  }

  @Test("Qwen3 audio models: CustomVoice from 16 GB, the 1.7B checkpoints from 32 GB")
  func qwen3AudioMemoryFloors() {
    #expect(Qwen3ModelType.customVoice.minimumPhysicalMemoryGB == 16)
    #expect(Qwen3ModelType.asr.minimumPhysicalMemoryGB == 32)
    #expect(Qwen3ModelType.voiceDesign.minimumPhysicalMemoryGB == 32)
  }

  @Test("Gemma 4 26B A4B is a Chat-only catalogue entry that needs 32 GB")
  func gemma426BA4BIsChatOnlyAndNeeds32GB() {
    #expect(PromptModel.forLocalLLMModel(.gemma426BA4B) == .localMLXGemma426BA4B)
    #expect(PromptModel.localMLXGemma426BA4B.localMLXModelType == .gemma426BA4B)
    #expect(PromptModel.localMLXGemma426BA4B.supportsDictatePrompt == false)
    #expect(PromptModel.localMLXQwen34BInstruct.supportsDictatePrompt == true)
    #expect(!PromptModel.dictatePromptCapableModels.contains(.localMLXGemma426BA4B))
    #expect(!LocalLLMModelType.byPreference.contains(.gemma426BA4B))
    #expect(LocalLLMModelType.gemma426BA4B.minimumPhysicalMemoryGB == 32)
    #expect(!LocalLLMModelType.gemma426BA4B.isRecommended)
    #expect(LLMProviderFactory.provider(for: .localMLXGemma426BA4B) is MLXChatProvider)
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

  // MARK: - On-disk completeness

  /// A cancelled download left shard 2 of 2 on disk and shard 1 as `.incomplete`. Accepting that
  /// folder as "downloaded" made MLX trap while loading it, so Chat crashed the whole app.
  @Test("A sharded model with a missing shard is not on disk")
  func missingShardIsIncomplete() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-shards-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["config.json", "tokenizer.json", "model-00002-of-00002.safetensors"] {
      try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
    }
    let index = #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#
    try Data(index.utf8).write(to: dir.appendingPathComponent("model.safetensors.index.json"))

    #expect(!MLXModelPaths.hasRequiredFiles(at: dir))

    try Data("{}".utf8).write(to: dir.appendingPathComponent("model-00001-of-00002.safetensors"))
    #expect(MLXModelPaths.hasRequiredFiles(at: dir))
  }

  /// Qwen3 does not require `tokenizer.json`, but a sharded download cancelled after one shard
  /// used to pass on "any .safetensors" and show up as installed.
  @Test("A half-downloaded sharded Qwen3 snapshot is not installed")
  func qwen3MissingShardIsIncomplete() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("qwen3-hub-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = HubSnapshotLayout(root: root, requiredFiles: ["config.json"])
    let repo = "mlx-community/Qwen3-ASR-1.7B-8bit"
    let snap = root
      .appendingPathComponent("models")
      .appendingPathComponent(repo)
      .appendingPathComponent("snapshots")
      .appendingPathComponent("hash")
    try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
    for name in ["config.json", "model-00002-of-00002.safetensors"] {
      try Data("{}".utf8).write(to: snap.appendingPathComponent(name))
    }
    let index =
      #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#
    try Data(index.utf8).write(to: snap.appendingPathComponent("model.safetensors.index.json"))

    #expect(layout.localDirectory(for: repo) == nil)

    try Data("{}".utf8).write(to: snap.appendingPathComponent("model-00001-of-00002.safetensors"))
    // Compared by path: the snapshot URL comes back from a directory listing with a trailing slash.
    #expect(layout.localDirectory(for: repo)?.standardizedFileURL.path == snap.standardizedFileURL.path)
    #expect(
      layout.deletionTarget(for: snap)
        == snap.deletingLastPathComponent().deletingLastPathComponent())
  }
}
