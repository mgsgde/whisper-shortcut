import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("ChatGPT plan Responses route")
struct ChatGPTPlanRequestTests {
  typealias P = ChatGPTPlanChatProvider

  private let contents: [[String: Any]] = [
    ["role": "user", "parts": [["text": "Hello"]]],
    ["role": "model", "parts": [["text": "Hi"]]],
    ["role": "user", "parts": [["text": "Summarize"]]],
  ]
  private let system: [String: Any] = ["parts": [["text": "You are helpful."]]]

  // MARK: Request body

  @Test("The body never stores, always streams and carries the system text as instructions")
  func bodyShape() throws {
    let body = P.requestBody(
      model: "gpt-6-sol", contents: contents, systemInstruction: system, thinkingLevel: .default)
    #expect(body["store"] as? Bool == false)
    #expect(body["stream"] as? Bool == true)
    #expect(body["model"] as? String == "gpt-6-sol")
    #expect(body["instructions"] as? String == "You are helpful.")
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 3)
    #expect(!input.contains { ($0["role"] as? String) == "system" })
  }

  @Test("None of the rejected fields is ever sent, and no tools")
  func noForbiddenFields() {
    let body = P.requestBody(
      model: "gpt-6-sol", contents: contents, systemInstruction: system, thinkingLevel: .high,
      structured: (name: "result", schema: ["type": "object", "properties": ["a": ["type": "string"]]]))
    for field in P.forbiddenRequestFields { #expect(body[field] == nil, "\(field) must not be sent") }
    #expect(body["tools"] == nil)
    #expect(body["tool_choice"] == nil)
  }

  @Test("Structured output uses a strict json_schema format")
  func structured() throws {
    let body = P.requestBody(
      model: "gpt-6-sol", contents: contents, systemInstruction: nil, thinkingLevel: .default,
      structured: (name: "result", schema: ["type": "object", "properties": ["a": ["type": "string"]]]))
    let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    #expect(format["strict"] as? Bool == true)
    #expect(format["name"] as? String == "result")
    #expect(body["instructions"] == nil)
  }

  @Test("Audio attachments are rejected before any request")
  func audioRejected() async {
    let audio: [[String: Any]] = [
      ["role": "user", "parts": [["inline_data": ["mime_type": "audio/wav", "data": "AAAA"]]]]
    ]
    let stream = P.shared.sendChatStream(
      model: ChatGPTPlanPreferences.sentinelModelRawValue, contents: audio, systemInstruction: nil,
      tools: [], options: ChatRequestOptions())
    await #expect(throws: (any Error).self) {
      for try await _ in stream {}
    }
  }

  // MARK: Catalog

  @Test("The catalog lists only visibility=list models and keeps their order")
  func catalog() {
    let json = """
      {"models":[
        {"slug":"gpt-6-sol","display_name":"GPT-6 Sol","visibility":"list"},
        {"slug":"hidden-one","display_name":"Hidden","visibility":"hide"},
        {"slug":"gpt-6-luna","visibility":"list"},
        {"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list"}]}
      """
    let entries = ChatGPTPlanModelCatalog.parse(Data(json.utf8))
    #expect(entries.map(\.slug) == ["gpt-6-sol", "gpt-6-luna", "gpt-5.5"])
    #expect(entries[1].displayName == "gpt-6-luna")
    #expect(ChatGPTPlanModelCatalog.parse(Data("{}".utf8)).isEmpty)
  }

  // MARK: Error mapping

  @Test("Each documented code maps to its error")
  func errorMapping() {
    func code(_ c: String, status: Int, param: String? = nil) -> ChatGPTPlanError {
      let paramPart = param.map { #","param":"\#($0)""# } ?? ""
      return ChatGPTPlanError.fromHTTP(
        status: status, body: #"{"error":{"code":"\#(c)","message":"m"\#(paramPart)}}"#)
    }
    #expect(code("subscription_sharing_usage_limit_exceeded", status: 429) == .usageLimit)
    #expect(code("subscription_sharing_user_not_eligible", status: 403) == .notEligible)
    #expect(code("subscription_sharing_usage_unavailable", status: 503) == .usageUnavailable)
    #expect(code("subscription_sharing_invalid_user", status: 401) == .signInRequired)
    #expect(
      code("subscription_sharing_unsupported_capability", status: 400, param: "temperature")
        == .unsupportedCapability(param: "temperature"))
  }

  @Test("Admission errors with only a detail map by status, others keep status, message and request id")
  func detailAndOther() {
    #expect(ChatGPTPlanError.fromHTTP(status: 401, body: #"{"detail":"Unauthorized"}"#) == .signInRequired)
    #expect(ChatGPTPlanError.fromHTTP(status: 503, body: #"{"detail":"down"}"#) == .usageUnavailable)
    let other = ChatGPTPlanError.fromHTTP(
      status: 500, body: #"{"error":{"code":"server_error","message":"boom","request_id":"req_abc123"}}"#)
    #expect(other == .other(status: 500, message: "boom", requestID: "req_abc123"))
  }

  @Test("The user-facing strings are the agreed wording")
  func messages() {
    #expect(
      ChatGPTPlanError.usageLimit.errorDescription
        == "You've reached the ChatGPT plan limit for WhisperShortcut. Check or raise it in ChatGPT Settings → Usage.")
    #expect(
      ChatGPTPlanError.usageUnavailable.errorDescription
        == "ChatGPT couldn't check your plan usage right now. Try again in a minute.")
  }

  // MARK: Stream terminal handling

  private func run(body: String, strict: Bool) async -> (events: Int, error: Error?) {
    let endpoint = OpenAICompatibleStreamTests.StubProtocol.register(status: 200, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAICompatibleStreamTests.StubProtocol.self]
    let config = OpenAICompatibleStream.Config(
      endpoint: endpoint, headers: [:], logTag: "TEST",
      mapHTTPError: { status, text in ChatGPTPlanError.fromHTTP(status: status, body: text) },
      session: URLSession(configuration: configuration),
      terminalFailure: strict ? { type, payload in ChatGPTPlanError.fromStreamFailure(type: type, payload: payload) } : nil)
    var count = 0
    do {
      for try await _ in OpenAICompatibleStream.responses(config, body: [:], collectCitations: false) { count += 1 }
      return (count, nil)
    } catch {
      return (count, error)
    }
  }

  private let delta = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n"
  private let completed = "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
  private let failed =
    "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"limit\"}}}\n\n"

  @Test("response.completed is a success")
  func completedOK() async {
    let result = await run(body: delta + completed, strict: true)
    #expect(result.error == nil)
    #expect(result.events > 0)
  }

  @Test("response.failed mid-stream surfaces the mapped usage-limit error")
  func failedMidStream() async {
    let result = await run(body: delta + failed, strict: true)
    #expect(result.error as? ChatGPTPlanError == .usageLimit)
  }

  @Test("A stream that ends without response.completed is an error")
  func endedEarly() async {
    let result = await run(body: delta, strict: true)
    #expect(result.error is ChatGPTPlanError)
  }

  @Test("Without the opt-in the parser stays lenient")
  func lenientUnchanged() async {
    let result = await run(body: delta, strict: false)
    #expect(result.error == nil)
  }
}
