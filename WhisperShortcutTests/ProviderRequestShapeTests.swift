import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Equivalence lock for the shared request-shape helpers that replaced per-provider copies.
///
/// The tool-declaration encoders, the system-instruction extractor, and the "convert + prepend
/// system message" step were each written out by hand in every OpenAI-compatible provider. These
/// tests pin the exact dictionaries the old copies produced, so a change to the shared helper that
/// would have silently altered one provider's wire format fails here instead.
@Suite("Provider request shapes")
struct ProviderRequestShapeTests {

  private static let sample = LLMToolDeclaration(
    name: "get_time",
    description: "Returns the current time.",
    parameters: ["type": "object", "properties": ["tz": ["type": "string"]] as [String: Any]])

  // MARK: - Tool declarations

  @Test("Chat Completions nests name/description/parameters under `function`")
  func chatCompletionsDeclarationShape() {
    let decl = Self.sample.chatCompletionsDeclaration

    #expect(decl["type"] as? String == "function")
    let function = try? #require(decl["function"] as? [String: Any])
    #expect(function?["name"] as? String == "get_time")
    #expect(function?["description"] as? String == "Returns the current time.")
    #expect((function?["parameters"] as? [String: Any])?["type"] as? String == "object")
    // The flat keys must NOT also appear at the top level — that shape belongs to Responses.
    #expect(decl["name"] == nil)
    #expect(decl.count == 2)
  }

  @Test("Responses keeps name/description/parameters flat on the tool object")
  func responsesDeclarationShape() {
    let decl = Self.sample.responsesDeclaration

    #expect(decl["type"] as? String == "function")
    #expect(decl["name"] as? String == "get_time")
    #expect(decl["description"] as? String == "Returns the current time.")
    #expect((decl["parameters"] as? [String: Any])?["type"] as? String == "object")
    // No nested `function` wrapper — sending one makes the Responses API reject the tool.
    #expect(decl["function"] == nil)
    #expect(decl.count == 4)
  }

  // MARK: - System instruction

  @Test("The system instruction is read out of the Gemini-format nested dict")
  func systemInstructionExtraction() {
    let sys: [String: Any] = ["parts": [["text": "Be brief."]]]
    #expect(GeminiSystemInstruction.text(from: sys) == "Be brief.")
  }

  @Test("Absent, malformed, and empty system instructions all read as nil")
  func systemInstructionAbsentCases() {
    // Every provider previously treated these three as "send no system message"; an extractor that
    // returned "" instead of nil would start emitting an empty system turn on all of them at once.
    #expect(GeminiSystemInstruction.text(from: nil) == nil)
    #expect(GeminiSystemInstruction.text(from: ["parts": []]) == nil)
    #expect(GeminiSystemInstruction.text(from: ["parts": [["text": ""]]]) == nil)
    #expect(GeminiSystemInstruction.text(from: ["unexpected": "shape"]) == nil)
  }

  // MARK: - Messages + system instruction

  @Test("The system message is prepended at index 0, ahead of the converted turns")
  func messagesPrependsSystem() {
    let contents: [[String: Any]] = [
      ["role": "user", "parts": [["text": "hi"]]],
      ["role": "model", "parts": [["text": "hello"]]],
    ]
    let messages = OpenAIChatCompletionsConverter.messages(
      from: contents, systemInstruction: ["parts": [["text": "Be brief."]]])

    #expect(messages.count == 3)
    #expect(messages[0]["role"] as? String == "system")
    #expect(messages[0]["content"] as? String == "Be brief.")
    #expect(messages[1]["role"] as? String == "user")
    #expect(messages[2]["role"] as? String == "assistant")
  }

  @Test("With no system instruction the output matches the plain converter exactly")
  func messagesWithoutSystemAreUnchanged() {
    let contents: [[String: Any]] = [["role": "user", "parts": [["text": "hi"]]]]
    let withNil = OpenAIChatCompletionsConverter.messages(from: contents, systemInstruction: nil)
    let plain = OpenAIChatCompletionsConverter.messages(from: contents)

    #expect(withNil.count == plain.count)
    #expect(withNil.first?["role"] as? String == plain.first?["role"] as? String)
    #expect(withNil.first?["content"] as? String == plain.first?["content"] as? String)
  }

  @Test("stripImages still reaches the converter through the system-instruction overload")
  func messagesForwardsStripImages() {
    let contents: [[String: Any]] = [
      [
        "role": "user",
        "parts": [
          ["text": "look"],
          ["inline_data": ["mime_type": "image/png", "data": "AAAA"]],
        ],
      ]
    ]
    let stripped = OpenAIChatCompletionsConverter.messages(
      from: contents, systemInstruction: nil, stripImages: true)
    let kept = OpenAIChatCompletionsConverter.messages(
      from: contents, systemInstruction: nil, stripImages: false)

    // Stripped: dropping the image leaves a text-only turn, which the converter collapses to a
    // plain string `content` rather than a one-element parts array.
    #expect(stripped.first?["content"] as? String == "look")
    // Kept: text part + image_url part.
    #expect((kept.first?["content"] as? [[String: Any]])?.count == 2)
  }
}

/// `x_search` account restriction (`/x` in chat, Settings → Chat default).
///
/// `allowed_x_handles` is an exclusive filter on xAI's side, so the two failure modes worth
/// pinning are opposite: sending the key with an empty array would restrict Grok to *no* accounts,
/// and sending more than the documented cap fails the whole request rather than truncating.
@Suite("Grok X search handles")
struct XSearchHandleTests {

  @Test("An empty list omits allowed_x_handles entirely rather than sending []")
  func emptyHandlesOmitTheKey() {
    let tool = GrokChatProvider.xSearchTool(handles: [])

    #expect(tool["type"] as? String == "x_search")
    // `allowed_x_handles: []` would mean "search these zero accounts", not "search all of X".
    #expect(tool["allowed_x_handles"] == nil)
    #expect(tool.count == 1)
  }

  @Test("Handles are sent as a plain string array beside the tool type")
  func handlesRideOnTheToolObject() {
    let tool = GrokChatProvider.xSearchTool(handles: ["karpathy", "simonw"])

    #expect(tool["type"] as? String == "x_search")
    #expect(tool["allowed_x_handles"] as? [String] == ["karpathy", "simonw"])
  }

  @Test("More handles than xAI accepts are capped, not passed through")
  func handlesAreCappedAtTheAPILimit() {
    let many = (1...(XSearchHandles.maxHandles + 5)).map { "user\($0)" }

    let tool = GrokChatProvider.xSearchTool(handles: many)

    #expect((tool["allowed_x_handles"] as? [String])?.count == XSearchHandles.maxHandles)
  }

  @Test("Pasted input is normalized to bare lowercase handles")
  func parsingAcceptsWhatUsersActuallyType() {
    // @-prefixes, commas, mixed case, and a pasted profile URL all reach the wire identically.
    let (handles, dropped) = XSearchHandles.parse("@Karpathy, simonw https://x.com/levelsio/")

    #expect(handles == ["karpathy", "simonw", "levelsio"])
    #expect(dropped == 0)
  }

  @Test("Duplicates collapse and unusable tokens are dropped")
  func parsingRejectsNonHandles() {
    // "sixteencharacters" exceeds X's 15-char limit; "a-b" and "" can't be handles at all.
    let (handles, _) = XSearchHandles.parse("@karpathy KARPATHY a-b sixteencharacters!")

    #expect(handles == ["karpathy"])
  }

  @Test("Going over the cap is reported, not silently swallowed")
  func parsingReportsTheOverflow() {
    let raw = (1...(XSearchHandles.maxHandles + 3)).map { "user\($0)" }.joined(separator: " ")

    let (handles, dropped) = XSearchHandles.parse(raw)

    #expect(handles.count == XSearchHandles.maxHandles)
    #expect(dropped == 3)
  }
}

/// Dispatch tests for the single tool entry point.
///
/// Session-scoped tools (generate_image, the meeting editors, the memory tools) used to be
/// intercepted by an if/else ladder in `ChatViewModel` *before* the registry saw them. These pin
/// the replacement contract: registered handlers win, everything else falls through to the built-in
/// table, and a name that matches neither still fails loudly rather than silently.
@Suite("Chat tool dispatch")
@MainActor
struct ChatToolDispatchTests {

  @Test("A registered session handler wins over the registry's own tool of the same name")
  func sessionHandlerTakesPrecedence() async {
    // Shadowing a real global tool proves precedence without touching the pasteboard.
    let context = ChatToolContext(sessionHandlers: [
      "read_clipboard": { _ in ChatToolOutcome(response: ["text": "from session"]) }
    ])
    let outcome = await ChatToolRegistry.execute(
      name: "read_clipboard", args: [:], context: context)

    #expect(outcome.response["text"] as? String == "from session")
  }

  @Test("Handlers receive the call's arguments")
  func sessionHandlerReceivesArgs() async {
    let context = ChatToolContext(sessionHandlers: [
      "echo": { args in ChatToolOutcome(response: ["echoed": args["value"] as? String ?? ""]) }
    ])
    let outcome = await ChatToolRegistry.execute(
      name: "echo", args: ["value": "hi"], context: context)

    #expect(outcome.response["echoed"] as? String == "hi")
  }

  @Test("Image markers travel beside the response, never inside it")
  func imageMarkersAreASideChannel() async {
    // The marker must stay out of `response`: that dict is round-tripped into the model's context,
    // and base64 image data there is exactly what the side channel exists to prevent.
    let context = ChatToolContext(sessionHandlers: [
      ChatToolRegistry.generateImageToolName: { _ in
        ChatToolOutcome(response: ["status": "success"], imageMarkers: ["⟦GEMINI_IMG:abc⟧"])
      }
    ])
    let outcome = await ChatToolRegistry.execute(
      name: ChatToolRegistry.generateImageToolName, args: [:], context: context)

    #expect(outcome.imageMarkers == ["⟦GEMINI_IMG:abc⟧"])
    #expect(outcome.response["status"] as? String == "success")
    #expect(outcome.response.count == 1)
  }

  @Test("An unregistered name still reaches the built-in table")
  func unregisteredNamesFallThrough() async {
    let context = ChatToolContext(sessionHandlers: [
      "something_else": { _ in ChatToolOutcome(response: ["unexpected": true]) }
    ])
    let outcome = await ChatToolRegistry.execute(
      name: "definitely_not_a_tool", args: [:], context: context)

    #expect((outcome.response["error"] as? String)?.contains("Unknown tool") == true)
  }

  @Test("With no context at all, global tools still dispatch")
  func emptyContextDispatchesGlobally() async {
    let outcome = await ChatToolRegistry.execute(name: "definitely_not_a_tool", args: [:])

    #expect((outcome.response["error"] as? String)?.contains("Unknown tool") == true)
  }
}
