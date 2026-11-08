import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the pure half of server discovery: what counts as an answer, and what the model list looks
/// like. No test here makes a request — a live probe would depend on whatever happens to be running
/// on the machine, which is exactly what the feature cannot assume.
@Suite("Local server discovery")
struct LocalServerDiscoveryTests {

  private func data(_ json: String) -> Data { Data(json.utf8) }

  // MARK: - Model list decoding

  @Test("A model list decodes to its ids in order")
  func decodesModelIDs() {
    let body = data(#"{"object":"list","data":[{"id":"a","object":"model"},{"id":"b","object":"model"}]}"#)
    #expect(LocalServerDiscovery.decodeModelIDs(from: body) == ["a", "b"])
  }

  @Test("An empty list is an answer, not a failure")
  func decodesEmptyList() {
    #expect(LocalServerDiscovery.decodeModelIDs(from: data(#"{"object":"list","data":[]}"#)) == [])
  }

  @Test("A body that is not a model list yields nothing", arguments: [
    "",
    "not json",
    #"{"data":"nope"}"#,
    #"{"object":"list"}"#,
    #"{"data":[{"object":"model"}]}"#,
    "<html><body>502 Bad Gateway</body></html>",
  ])
  func rejectsMalformedBodies(body: String) {
    #expect(LocalServerDiscovery.decodeModelIDs(from: data(body)) == nil)
  }

  // MARK: - A response becomes a server, or does not

  @Test("A 2xx with a model list becomes a server")
  func acceptsSuccess() throws {
    let body = data(#"{"object":"list","data":[{"id":"mlx-community/Qwen3-ASR-0.6B-8bit"}]}"#)
    let server = try #require(LocalServerDiscovery.server(
      baseURL: "http://localhost:8000/v1",
      kind: .unknown,
      statusCode: 200,
      data: body))

    #expect(server.baseURL == "http://localhost:8000/v1")
    #expect(server.host == "localhost:8000")
    #expect(server.kind == .unknown)
    #expect(server.modelIDs == ["mlx-community/Qwen3-ASR-0.6B-8bit"])
    #expect(server.id == server.baseURL)
  }

  @Test("A non-2xx status yields no server, even with a valid body", arguments: [301, 400, 401, 404, 500, 503])
  func rejectsNonSuccessStatus(statusCode: Int) {
    let body = data(#"{"object":"list","data":[{"id":"a"}]}"#)
    #expect(LocalServerDiscovery.server(
      baseURL: "http://localhost:8000/v1",
      kind: .unknown,
      statusCode: statusCode,
      data: body) == nil)
  }

  @Test("A 2xx with a malformed body yields no server")
  func rejectsMalformedBody() {
    #expect(LocalServerDiscovery.server(
      baseURL: "http://localhost:8000/v1",
      kind: .unknown,
      statusCode: 200,
      data: data("<html>hello</html>")) == nil)
  }

  // MARK: - URL shaping (probe only; the form field keeps what was typed)

  @Test("The probe URL is {base}/v1/models", arguments: [
    ("http://localhost:8000/v1", "http://localhost:8000/v1/models"),
    ("http://localhost:8000/v1/", "http://localhost:8000/v1/models"),
    ("http://localhost:8000", "http://localhost:8000/v1/models"),
    ("http://localhost:8000/", "http://localhost:8000/v1/models"),
    ("https://example.com/openai/v1", "https://example.com/openai/v1/models"),
    // A pasted full endpoint URL is stripped first, exactly as `CustomEndpointAuth` does for the
    // real request — otherwise a running server would report "no answer".
    ("http://localhost:8000/v1/audio/transcriptions", "http://localhost:8000/v1/models"),
    ("http://localhost:8000/v1/chat/completions", "http://localhost:8000/v1/models"),
    ("http://localhost:8000/v1/audio/speech", "http://localhost:8000/v1/models"),
  ])
  func shapesProbeURL(base: String, expected: String) {
    #expect(LocalServerDiscovery.modelsURL(forBaseURL: base)?.absoluteString == expected)
  }

  @Test("A URL without a host has no probe URL", arguments: ["", "   ", "localhost:8000", "/v1"])
  func rejectsHostlessURLs(base: String) {
    #expect(LocalServerDiscovery.modelsURL(forBaseURL: base) == nil)
  }

  @Test("The host label is host:port")
  func hostLabel() {
    #expect(LocalServerDiscovery.hostLabel(forBaseURL: "http://localhost:1234/v1") == "localhost:1234")
    #expect(LocalServerDiscovery.hostLabel(forBaseURL: "https://example.com/v1") == "example.com")
  }

  // MARK: - Candidate ports

  @Test("The five usual ports are probed, in the documented order")
  func candidatePorts() {
    #expect(LocalServerDiscovery.candidates.map(\.port) == [8000, 1234, 4000, 11434, 8080])
    #expect(LocalServerDiscovery.candidates.map(\.kind) == [.unknown, .lmStudio, .liteLLM, .ollama, .llamaCpp])
  }

  @Test("A typed URL is labelled by its port when it is a known one")
  func kindFromPort() {
    #expect(LocalServerDiscovery.kind(forBaseURL: "http://localhost:8000/v1") == .unknown)
    #expect(LocalServerDiscovery.kind(forBaseURL: "http://127.0.0.1:11434/v1") == .ollama)
    #expect(LocalServerDiscovery.kind(forBaseURL: "https://example.com/v1") == .unknown)
  }
}
