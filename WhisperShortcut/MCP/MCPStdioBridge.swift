import Foundation
import os

/// Stdio ↔ HTTP bridge for clients that can only launch a local process (Claude Desktop).
///
/// The running menu-bar app keeps serving `POST /mcp`. Claude starts this same binary with
/// `--mcp-stdio`; that process never opens a window. It reads one JSON-RPC message per stdin
/// line, POSTs it to `WHISPERSHORTCUT_MCP_URL`, and writes the reply to stdout.
///
/// stdout carries only JSON-RPC lines. Diagnostics go to stderr. Do not use `DebugLogger` or
/// `print()` here — both can write to stdout and break the protocol.
enum MCPStdioBridge {
  static let argument = "--mcp-stdio"
  static let urlEnv = "WHISPERSHORTCUT_MCP_URL"
  static let authEnv = "WHISPERSHORTCUT_MCP_AUTH"

  enum Outcome {
    case http(status: Int, body: Data)
    case unreachable
  }

  private static let notRunning = "WhisperShortcut is not running. Open WhisperShortcut and try again."
  private static let accessKeyChanged =
    "WhisperShortcut's access key changed. In WhisperShortcut, open Settings → AI apps and click Reconnect next to Claude Desktop."
  private static let requestTimeout: TimeInterval = 300

  /// One JSON-RPC reply line, or nil when the client should hear nothing (notification, HTTP 202,
  /// empty HTTP 200).
  static func reply(forLine line: String, outcome: Outcome) -> String? {
    let shape = requestShape(line)

    if case .http(let status, let body) = outcome {
      if status == 200, !body.isEmpty {
        if let forwarded = compactJSON(body) { return forwarded }
      } else if status == 202 || (status == 200 && body.isEmpty) {
        return nil
      }
    }

    let message: String
    let statusWas200: Bool
    switch outcome {
    case .unreachable:
      message = notRunning
      statusWas200 = false
    case .http(let status, _):
      statusWas200 = status == 200
      message = status == 401 ? accessKeyChanged : "WhisperShortcut answered with HTTP \(status)."
    }

    // A line that is not JSON is a parse error, unless the app already answered 200 and the
    // failure is the body rather than the request.
    let code = (shape.isUnparseable && !statusWas200) ? -32700 : -32000
    return errorLine(shape: shape, code: code, message: message)
  }

  /// Reads stdin until EOF, forwards each line, then exits. Never returns.
  static func run() -> Never {
    let env = ProcessInfo.processInfo.environment
    let urlString = env[urlEnv] ?? ""
    let auth = env[authEnv] ?? ""
    guard !urlString.isEmpty, !auth.isEmpty, let url = URL(string: urlString) else {
      writeStderr("WhisperShortcut: \(argument) requires \(urlEnv) and \(authEnv).")
      exit(1)
    }

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = requestTimeout
    config.timeoutIntervalForResource = requestTimeout
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config)
    let stdoutQueue = DispatchQueue(label: "com.magnusgoedde.whispershortcut.mcp-stdio.stdout")
    let group = DispatchGroup()

    // Own thread: `readLine` blocks, and URLSession must not need this thread to finish.
    DispatchQueue.global(qos: .userInitiated).async {
      while let line = readLine(strippingNewline: true) {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
          defer { group.leave() }
          let outcome = post(line, to: url, auth: auth, session: session)
          guard let reply = reply(forLine: line, outcome: outcome) else { return }
          stdoutQueue.sync {
            fflush(stdout)
            var data = Data(reply.utf8)
            data.append(0x0A)
            try? FileHandle.standardOutput.write(contentsOf: data)
          }
        }
      }
      group.wait()
      exit(0)
    }
    dispatchMain()
  }

  // MARK: - HTTP

  private static func post(_ line: String, to url: URL, auth: String, session: URLSession) -> Outcome {
    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(auth, forHTTPHeaderField: "Authorization")
    request.httpBody = Data(line.utf8)

    let box = OSAllocatedUnfairLock<Outcome>(initialState: .unreachable)
    let done = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { data, response, error in
      let outcome: Outcome
      if let http = response as? HTTPURLResponse, error == nil {
        outcome = .http(status: http.statusCode, body: data ?? Data())
      } else {
        outcome = .unreachable
      }
      box.withLock { $0 = outcome }
      done.signal()
    }
    task.resume()
    if done.wait(timeout: .now() + requestTimeout + 10) == .timedOut {
      task.cancel()
      return .unreachable
    }
    return box.withLock { $0 }
  }

  private static func writeStderr(_ line: String) {
    let text = line.hasSuffix("\n") ? line : line + "\n"
    try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
  }

  // MARK: - JSON-RPC mapping

  private enum RequestShape {
    case unparseable
    case one(id: Any?)
    case batch(ids: [Any])

    var isUnparseable: Bool {
      if case .unparseable = self { return true }
      return false
    }
  }

  /// Object with an `id` → that id (JSON null included). Array → ids of elements that have one.
  /// Anything that is not JSON → unparseable.
  private static func requestShape(_ line: String) -> RequestShape {
    guard let data = line.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return .unparseable }

    // NSDictionary, not [String: Any]: a JSON null bridges to nil on the Swift subscript.
    if let object = parsed as? NSDictionary {
      if let id = object["id"] { return .one(id: id) }
      return .one(id: nil)
    }
    if let batch = parsed as? [Any] {
      var ids: [Any] = []
      for element in batch {
        guard let object = element as? NSDictionary, let id = object["id"] else { continue }
        ids.append(id)
      }
      return .batch(ids: ids)
    }
    return .unparseable
  }

  private static func errorLine(shape: RequestShape, code: Int, message: String) -> String? {
    switch shape {
    case .unparseable:
      return jsonLine(rpcError(id: NSNull(), code: code, message: message))
    case .one(let id):
      guard let id else { return nil }
      return jsonLine(rpcError(id: id, code: code, message: message))
    case .batch(let ids):
      guard !ids.isEmpty else { return nil }
      return jsonLine(ids.map { rpcError(id: $0, code: code, message: message) })
    }
  }

  private static func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
    [
      "jsonrpc": "2.0",
      "id": id,
      "error": ["code": code, "message": message] as [String: Any],
    ]
  }

  private static func compactJSON(_ body: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
      return nil
    }
    return jsonLine(object)
  }

  private static func jsonLine(_ object: Any) -> String? {
    let options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .fragmentsAllowed]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
