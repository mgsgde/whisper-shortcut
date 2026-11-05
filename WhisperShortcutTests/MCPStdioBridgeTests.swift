import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The stdio bridge's line→reply mapping. Claude Desktop speaks newline-delimited JSON-RPC;
/// the running app speaks one HTTP response per POST. These tests pin that translation.
@Suite("MCP stdio bridge")
struct MCPStdioBridgeTests {

  private let notRunning = "WhisperShortcut is not running. Open WhisperShortcut and try again."
  private let accessKeyChanged =
    "WhisperShortcut's access key changed. In WhisperShortcut, open Settings → AI apps and click Reconnect next to Claude Desktop."

  private func object(_ text: String?) throws -> NSDictionary {
    let data = try #require(text?.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  private func canonical(_ data: Data) throws -> String {
    let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    let out = try JSONSerialization.data(
      withJSONObject: parsed, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    return String(decoding: out, as: UTF8.self)
  }

  @Test("200 object is passed through on one line")
  func passthrough() throws {
    let body = Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8)
    let out = try #require(
      MCPStdioBridge.reply(
        forLine: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        outcome: .http(status: 200, body: body)))
    #expect(!out.contains("\n"))
    let forwarded = try canonical(Data(out.utf8))
    let original = try canonical(body)
    #expect(forwarded == original)
  }

  @Test("200 pretty-printed body comes out as a single line")
  func prettyBecomesOneLine() throws {
    let pretty = Data(
      """
      {
        "jsonrpc" : "2.0",
        "id" : 1,
        "result" : {
          "url" : "http:\\/\\/127.0.0.1\\/mcp"
        }
      }
      """.utf8)
    let out = try #require(
      MCPStdioBridge.reply(
        forLine: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
        outcome: .http(status: 200, body: pretty)))
    #expect(!out.contains("\n"))
    #expect(!out.contains("\\/"))
    #expect(out.contains("http://127.0.0.1/mcp"))
    let forwarded = try canonical(Data(out.utf8))
    let original = try canonical(pretty)
    #expect(forwarded == original)
  }

  @Test("202 and an empty 200 produce no reply")
  func acceptedIsSilent() {
    let line = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    #expect(MCPStdioBridge.reply(forLine: line, outcome: .http(status: 202, body: Data())) == nil)
    #expect(MCPStdioBridge.reply(forLine: line, outcome: .http(status: 200, body: Data())) == nil)
  }

  @Test("A notification with no id is silent when the app is unreachable")
  func notificationUnreachable() {
    let line = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    #expect(MCPStdioBridge.reply(forLine: line, outcome: .unreachable) == nil)
  }

  @Test("A request id is kept, with the not-running message, when the app is unreachable")
  func requestUnreachable() throws {
    let line = #"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}"#
    let parsed = try object(MCPStdioBridge.reply(forLine: line, outcome: .unreachable))
    #expect(parsed["jsonrpc"] as? String == "2.0")
    #expect(parsed["id"] as? Int == 7)
    let error = try #require(parsed["error"] as? [String: Any])
    #expect(error["code"] as? Int == -32000)
    #expect(error["message"] as? String == notRunning)
  }

  @Test("A string id is preserved")
  func stringId() throws {
    let line = #"{"jsonrpc":"2.0","id":"req-9","method":"tools/list"}"#
    let parsed = try object(MCPStdioBridge.reply(forLine: line, outcome: .unreachable))
    #expect(parsed["id"] as? String == "req-9")
    let error = try #require(parsed["error"] as? [String: Any])
    #expect(error["code"] as? Int == -32000)
    #expect(error["message"] as? String == notRunning)
  }

  @Test("HTTP 401 tells the user to reconnect")
  func unauthorized() throws {
    let line = #"{"jsonrpc":"2.0","id":3,"method":"initialize"}"#
    let body = Data(#"{"error":"unauthorized"}"#.utf8)
    let parsed = try object(MCPStdioBridge.reply(forLine: line, outcome: .http(status: 401, body: body)))
    #expect(parsed["id"] as? Int == 3)
    let error = try #require(parsed["error"] as? [String: Any])
    #expect(error["code"] as? Int == -32000)
    #expect(error["message"] as? String == accessKeyChanged)
  }

  @Test("A batch yields one error per element that has an id")
  func batchUnreachable() throws {
    let line =
      #"[{"jsonrpc":"2.0","id":1,"method":"a"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"b"}]"#
    let text = try #require(MCPStdioBridge.reply(forLine: line, outcome: .unreachable))
    #expect(!text.contains("\n"))
    let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [NSDictionary])
    #expect(parsed.count == 2)
    #expect(parsed[0]["id"] as? Int == 1)
    #expect(parsed[1]["id"] as? Int == 2)
    for item in parsed {
      let error = try #require(item["error"] as? [String: Any])
      #expect(error["code"] as? Int == -32000)
      #expect(error["message"] as? String == notRunning)
    }
  }

  @Test("An unparseable line is a parse error with a null id")
  func garbageUnreachable() throws {
    let parsed = try object(MCPStdioBridge.reply(forLine: "NOT JSON {{{", outcome: .unreachable))
    let id = try #require(parsed["id"])
    #expect(id is NSNull)
    let error = try #require(parsed["error"] as? [String: Any])
    #expect(error["code"] as? Int == -32700)
    #expect(error["message"] as? String == notRunning)
  }
}
