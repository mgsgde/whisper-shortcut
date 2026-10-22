import Foundation

/// A one-shot HTTP listener on 127.0.0.1 that catches an OAuth redirect.
///
/// Exists because OpenRouter does not accept a custom URL scheme as `callback_url`: sending
/// `whispershortcut://…` makes `openrouter.ai/auth` drop the request and land the user on the
/// homepage with no consent screen and no error. Its docs name exactly two forms — a public https
/// URL and `localhost` on any port — so loopback is the option that needs no web hosting.
///
/// The sockets are `LoopbackHTTPServer` (port 0, one shot). This used to be a second BSD-socket
/// server beside that one, without `SO_NOSIGPIPE`, recv/send timeouts, or a read/send loop, so a
/// split redirect could sit in `recv` until the user gave up. `NWListener` is not an option: it
/// failed to start with `NWError 22 (EINVAL)`.
///
/// Deliberately single-use: it stops after the first request, so a stale listener cannot linger and
/// accept a replayed code. Requires `com.apple.security.network.server` in the sandbox entitlements.
final class LoopbackOAuthListener {
  /// Defaults keep OpenRouter's behaviour: any path works for it, a fixed one keeps the logs readable.
  /// ChatGPT's sign-in requires exactly `/auth/callback` (see `ChatGPTPlanOAuthConfig`).
  static let defaultCallbackPath = "/openrouter-callback"
  static let defaultProviderName = "OpenRouter"

  private let server: LoopbackHTTPServer
  private let once: Once

  /// The URL to hand the authorization server.
  let callbackURL: String

  /// Binds an OS-assigned free port on the loopback interface and begins accepting.
  ///
  /// - Parameters:
  ///   - callbackPath: path of the redirect URI the authorization server is told about.
  ///   - providerName: shown on the browser page ("WhisperShortcut has your … connection").
  ///   - onRequest: called at most once, on the main queue, with the redirect's query
  ///     components (nil if the request could not be parsed). The listener is stopped when it fires.
  init(
    callbackPath: String = LoopbackOAuthListener.defaultCallbackPath,
    providerName: String = LoopbackOAuthListener.defaultProviderName,
    onRequest: @escaping (URLComponents?) -> Void
  ) throws {
    let once = Once(onRequest)
    let server: LoopbackHTTPServer
    do {
      server = try LoopbackHTTPServer(
        port: 0,
        oneShot: true,
        onUnparsed: {
          HTTPResponse.html(Self.browserPage(success: false, providerName: providerName))
        },
        afterResponse: { request in
          once.fire(request.flatMap(Self.components(from:)))
        }
      ) { request in
        let components = Self.components(from: request)
        let succeeded = components?.queryItems?.contains { $0.name == "code" } == true
        return HTTPResponse.html(Self.browserPage(success: succeeded, providerName: providerName))
      }
    } catch let error as LoopbackHTTPServer.ServerError {
      throw Self.listenerError(from: error)
    } catch {
      throw error
    }
    self.server = server
    self.once = once
    callbackURL = "http://127.0.0.1:\(server.port)\(callbackPath)"
    DebugLogger.log("OAUTH-LOOPBACK: Listening on \(callbackURL)")
  }

  deinit {
    stop()
  }

  /// Safe to call repeatedly and from any thread.
  func stop() {
    once.cancel()
    server.stop()
  }

  // MARK: - HTTP

  /// Pulls the request target out of an HTTP request line ("GET /path?query HTTP/1.1").
  ///
  /// Parsing only the first line is enough — the authorization server redirects with a plain GET
  /// and everything we need is in the query string.
  static func parseRequestTarget(_ data: Data) -> URLComponents? {
    guard let text = String(data: data, encoding: .utf8),
          let firstLine = text.split(separator: "\r\n", maxSplits: 1).first
    else { return nil }

    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else { return nil }

    return URLComponents(string: "http://127.0.0.1\(parts[1])")
  }

  static func httpResponse(success: Bool, providerName: String = defaultProviderName) -> Data {
    let bodyData = Data(browserPage(success: success, providerName: providerName).utf8)
    let headers = """
      HTTP/1.1 200 OK\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(bodyData.count)\r
      Connection: close\r
      \r

      """
    return Data(headers.utf8) + bodyData
  }

  enum ListenerError: LocalizedError {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    var errorDescription: String? {
      switch self {
      case .socketFailed(let code):
        return "Could not open a local socket for the sign-in callback (errno \(code))."
      case .bindFailed(let code):
        return "Could not bind a local port for the sign-in callback (errno \(code))."
      case .listenFailed(let code):
        return "Could not listen on the local sign-in callback port (errno \(code))."
      }
    }
  }

  /// GET only, same as `parseRequestTarget`. The shared server uppercases the method and keeps the
  /// query that this listener's old parser read off the request line.
  private static func components(from request: HTTPRequest) -> URLComponents? {
    guard request.method == "GET" else { return nil }
    let target = request.query.isEmpty ? request.path : "\(request.path)?\(request.query)"
    return URLComponents(string: "http://127.0.0.1\(target)")
  }

  private static func browserPage(success: Bool, providerName: String) -> String {
    let title = success ? "You're connected" : "Something went wrong"
    let message = success
      ? "WhisperShortcut has your \(providerName) connection. You can close this tab."
      : "WhisperShortcut didn't receive an authorization code. Close this tab and try again."

    return """
      <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title><style>
      body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;
      justify-content:center;height:100vh;margin:0;background:#111;color:#eee}
      div{text-align:center;max-width:28rem;padding:2rem}h1{font-size:1.25rem;margin:0 0 .5rem}
      p{color:#aaa;margin:0;line-height:1.5}</style></head>
      <body><div><h1>\(title)</h1><p>\(message)</p></div></body></html>
      """
  }

  private static func listenerError(from error: LoopbackHTTPServer.ServerError) -> ListenerError {
    switch error {
    case .socketFailed(let code): return .socketFailed(code)
    case .bindFailed(let code): return .bindFailed(code)
    case .listenFailed(let code): return .listenFailed(code)
    }
  }

  /// The callback fires at most once, on the main queue, and `stop()` drops a late one.
  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLComponents?) -> Void)?

    init(_ handler: @escaping (URLComponents?) -> Void) {
      self.handler = handler
    }

    func fire(_ components: URLComponents?) {
      lock.lock()
      let callback = handler
      handler = nil
      lock.unlock()
      guard let callback else { return }
      DispatchQueue.main.async { callback(components) }
    }

    func cancel() {
      lock.lock()
      handler = nil
      lock.unlock()
    }
  }
}
