import Darwin
import Foundation

/// A one-shot HTTP listener on 127.0.0.1 that catches an OAuth redirect.
///
/// Exists because OpenRouter does not accept a custom URL scheme as `callback_url`: sending
/// `whispershortcut://…` makes `openrouter.ai/auth` drop the request and land the user on the
/// homepage with no consent screen and no error. Its docs name exactly two forms — a public https
/// URL and `localhost` on any port — so loopback is the option that needs no web hosting.
///
/// Uses BSD sockets rather than `NWListener`, which failed to start with `NWError 22 (EINVAL)`.
/// The socket path is about forty lines, has no state machine to get wrong, and binds explicitly to
/// `127.0.0.1` so the authorization code is never reachable from the local network.
///
/// Deliberately single-use: it stops after the first request, so a stale listener cannot linger and
/// accept a replayed code. Requires `com.apple.security.network.server` in the sandbox entitlements.
final class LoopbackOAuthListener {
  /// Path OpenRouter is told to redirect to. Any path works; a fixed one keeps the logs readable.
  private static let callbackPath = "/openrouter-callback"

  private let socketFD: Int32
  private let lock = NSLock()
  private var onRequest: ((URLComponents?) -> Void)?
  private var isStopped = false

  /// The URL to hand the authorization server.
  let callbackURL: String

  /// Binds an OS-assigned free port on the loopback interface and begins accepting.
  ///
  /// - Parameter onRequest: called at most once, on the main queue, with the redirect's query
  ///   components (nil if the request could not be parsed). The listener is stopped when it fires.
  init(onRequest: @escaping (URLComponents?) -> Void) throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ListenerError.socketFailed(errno) }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0  // let the kernel pick a free port
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let didBind = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard didBind == 0 else {
      let code = errno
      close(fd)
      throw ListenerError.bindFailed(code)
    }

    guard listen(fd, 1) == 0 else {
      let code = errno
      close(fd)
      throw ListenerError.listenFailed(code)
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &boundAddress) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    let port = UInt16(bigEndian: boundAddress.sin_port)

    socketFD = fd
    self.onRequest = onRequest
    callbackURL = "http://127.0.0.1:\(port)\(Self.callbackPath)"

    DebugLogger.log("OAUTH-LOOPBACK: Listening on \(callbackURL)")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptOnce() }
  }

  deinit {
    stop()
  }

  /// Safe to call repeatedly and from any thread.
  func stop() {
    lock.lock()
    let alreadyStopped = isStopped
    isStopped = true
    onRequest = nil
    lock.unlock()

    // Closing the socket is what unblocks the accept() below.
    if !alreadyStopped { close(socketFD) }
  }

  // MARK: - Accept

  private func acceptOnce() {
    let client = accept(socketFD, nil, nil)
    guard client >= 0 else {
      // Expected when stop() closed the socket out from under us — the user cancelled.
      return
    }
    defer { close(client) }

    var buffer = [UInt8](repeating: 0, count: 8192)
    let received = recv(client, &buffer, buffer.count, 0)
    let components = received > 0
      ? Self.parseRequestTarget(Data(buffer[0..<received]))
      : nil

    let succeeded = components?.queryItems?.contains { $0.name == "code" } == true
    let response = Self.httpResponse(success: succeeded)
    _ = response.withUnsafeBytes { send(client, $0.baseAddress, response.count, 0) }

    fireOnce(with: components)
  }

  private func fireOnce(with components: URLComponents?) {
    lock.lock()
    let callback = onRequest
    onRequest = nil
    let alreadyStopped = isStopped
    isStopped = true
    lock.unlock()

    if !alreadyStopped { close(socketFD) }
    guard let callback else { return }
    DispatchQueue.main.async { callback(components) }
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

  private static func httpResponse(success: Bool) -> Data {
    let title = success ? "You're connected" : "Something went wrong"
    let message = success
      ? "WhisperShortcut has your OpenRouter connection. You can close this tab."
      : "WhisperShortcut didn't receive an authorization code. Close this tab and try again."

    let body = """
      <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title><style>
      body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;
      justify-content:center;height:100vh;margin:0;background:#111;color:#eee}
      div{text-align:center;max-width:28rem;padding:2rem}h1{font-size:1.25rem;margin:0 0 .5rem}
      p{color:#aaa;margin:0;line-height:1.5}</style></head>
      <body><div><h1>\(title)</h1><p>\(message)</p></div></body></html>
      """

    let bodyData = Data(body.utf8)
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
}
