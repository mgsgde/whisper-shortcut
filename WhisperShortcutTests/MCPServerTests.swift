import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("MCP server")
struct MCPServerTests {

  private let token = "secret-token"

  private func tools() -> MCPMeetingTools {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-srv-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? "[00:05] Speaker A: Hi there\n".write(to: dir.appendingPathComponent("Meeting-2026-10-19-110109.txt"), atomically: true, encoding: .utf8)
    return MCPMeetingTools(meetingsDirectory: dir, liveStem: { "Meeting-2026-10-19-110109" })
  }

  private func req(
    _ method: String = "POST", path: String = "/mcp", auth: String? = "Bearer secret-token",
    origin: String? = nil, body: String = ""
  ) -> HTTPRequest {
    var h: [String: String] = [:]
    if let auth { h["authorization"] = auth }
    if let origin { h["origin"] = origin }
    return HTTPRequest(method: method, path: path, headers: h, body: Data(body.utf8))
  }

  private func rpc(_ body: String) -> HTTPResponse {
    MCPServer.handle(req(body: body), expectedToken: token, tools: tools())
  }

  private func json(_ r: HTTPResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
  }

  // MARK: parser

  @Test("Parser reads headers and body")
  func parser() throws {
    let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nAuthorization: Bearer t\r\n\r\nhello"
    guard case .complete(let r) = LoopbackHTTPServer.parse(Data(raw.utf8)) else { Issue.record("not complete"); return }
    #expect(r.method == "POST")
    #expect(r.path == "/mcp")
    #expect(r.header("AUTHORIZATION") == "Bearer t")
    #expect(String(data: r.body, encoding: .utf8) == "hello")
  }

  @Test("Parser reports partial input as incomplete")
  func parserPartial() {
    guard case .incomplete = LoopbackHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Le".utf8)) else { Issue.record("expected incomplete"); return }
    guard case .incomplete = LoopbackHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel".utf8)) else { Issue.record("expected incomplete body"); return }
  }

  @Test("Parser rejects oversized bodies")
  func parserTooLarge() {
    guard case .tooLarge = LoopbackHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n".utf8)) else { Issue.record("expected tooLarge"); return }
  }

  // MARK: handle

  @Test("Auth, origin, method and path checks")
  func guards() {
    let t = tools()
    #expect(MCPServer.handle(req(auth: nil), expectedToken: token, tools: t).status == 401)
    #expect(MCPServer.handle(req(auth: "Bearer nope"), expectedToken: token, tools: t).status == 401)
    #expect(MCPServer.handle(req(origin: "https://evil.example"), expectedToken: token, tools: t).status == 403)
    #expect(MCPServer.handle(req(origin: "http://localhost:3000", body: "{}"), expectedToken: token, tools: t).status != 403)
    let get = MCPServer.handle(req("GET"), expectedToken: token, tools: t)
    #expect(get.status == 405)
    #expect(get.headers["Allow"] == "POST")
    #expect(MCPServer.handle(req(path: "/other"), expectedToken: token, tools: t).status == 404)
  }

  @Test("initialize negotiates protocol version")
  func initialize() throws {
    let a = try json(rpc(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#))
    #expect((a["result"] as? [String: Any])?["protocolVersion"] as? String == "2024-11-05")
    let b = try json(rpc(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
    let result = try #require(b["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-06-18")
    #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "whisper-shortcut")
  }

  @Test("tools/list names the four tools")
  func list() throws {
    let r = try json(rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
    let list = try #require((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(Set(list.compactMap { $0["name"] as? String }) == ["get_live_transcript", "list_meetings", "get_meeting", "search_meetings"])
  }

  @Test("tools/call returns text content")
  func call() throws {
    let r = try json(rpc(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_live_transcript","arguments":{}}}"#))
    let result = try #require(r["result"] as? [String: Any])
    let content = try #require(result["content"] as? [[String: Any]])
    #expect((content.first?["text"] as? String)?.contains("Hi there") == true)
    #expect(result["isError"] as? Bool == false)
  }

  @Test("Notifications get 202, unknown methods -32601, bad JSON -32700, missing params -32602")
  func errors() throws {
    let n = rpc(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    #expect(n.status == 202)
    #expect(n.body.isEmpty)
    let u = try json(rpc(#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#))
    #expect((u["error"] as? [String: Any])?["code"] as? Int == -32601)
    let b = try json(rpc("{not json"))
    #expect((b["error"] as? [String: Any])?["code"] as? Int == -32700)
    let p = try json(rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#))
    #expect((p["error"] as? [String: Any])?["code"] as? Int == -32602)
  }

  @Test("Batches return an array")
  func batch() throws {
    let r = rpc(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#)
    let arr = try #require(try JSONSerialization.jsonObject(with: r.body) as? [[String: Any]])
    #expect(arr.count == 2)
  }

  // MARK: integration

  @Test("Real socket round trip")
  func integration() async throws {
    let t = tools()
    let server = try LoopbackHTTPServer(port: 0) { MCPServer.handle($0, expectedToken: "secret-token", tools: t) }
    defer { server.stop() }
    #expect(server.port > 0)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/mcp")!)
    request.httpMethod = "POST"
    request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
    request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(obj?["id"] as? Int == 1)

    request.setValue(nil, forHTTPHeaderField: "Authorization")
    let (_, denied) = try await URLSession.shared.data(for: request)
    #expect((denied as? HTTPURLResponse)?.statusCode == 401)
  }
}
