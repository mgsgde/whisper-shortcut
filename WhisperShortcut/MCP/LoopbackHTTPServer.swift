import Darwin
import Foundation

struct HTTPRequest {
  let method: String
  let path: String
  /// Lowercased header names.
  let headers: [String: String]
  let body: Data

  func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
  var status: Int
  var headers: [String: String] = [:]
  var body: Data = Data()
  var contentType: String = "application/json"

  static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
    return HTTPResponse(status: status, body: data)
  }

  static func empty(_ status: Int, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers)
  }
}

/// A long-running HTTP/1.1 server on 127.0.0.1 built on BSD sockets (NWListener failed with EINVAL
/// in this app, see `LoopbackOAuthListener`). One request per connection, `Connection: close`.
final class LoopbackHTTPServer {
  static let maxBodyBytes = 1_048_576
  private static let maxHeaderBytes = 32 * 1024

  enum ServerError: LocalizedError {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    var errno: Int32 {
      switch self {
      case .socketFailed(let c), .bindFailed(let c), .listenFailed(let c): return c
      }
    }

    var errorDescription: String? {
      switch self {
      case .socketFailed(let c): return "Could not open a local socket (errno \(c): \(String(cString: strerror(c))))."
      case .bindFailed(let c): return "Could not bind the local port (errno \(c): \(String(cString: strerror(c))))."
      case .listenFailed(let c): return "Could not listen on the local port (errno \(c): \(String(cString: strerror(c))))."
      }
    }
  }

  enum ParseResult {
    case incomplete
    case complete(HTTPRequest)
    case tooLarge
    case malformed
  }

  /// The port actually bound (differs from the requested one when 0 was passed).
  let port: UInt16

  private let socketFD: Int32
  private let handler: (HTTPRequest) -> HTTPResponse
  /// Called once, off the accept thread's loop, when the server gives up accepting new
  /// connections after an unexpected error (anything other than EINTR/ECONNABORTED/EMFILE/ENFILE).
  private let onFailure: (String) -> Void
  private let lock = NSLock()
  private var isStopped = false
  private let workQueue = DispatchQueue(label: "mcp.loopback.http.work", qos: .userInitiated, attributes: .concurrent)
  /// Caps connections actually being served; beyond this, new connections get a fast 503 instead of
  /// piling up worker threads behind a slow or stalled client.
  private let connectionSemaphore = DispatchSemaphore(value: 6)

  init(
    port requestedPort: UInt16, onFailure: @escaping (String) -> Void = { _ in },
    handler: @escaping (HTTPRequest) -> HTTPResponse
  ) throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ServerError.socketFailed(errno) }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = requestedPort.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let didBind = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard didBind == 0 else {
      let code = errno
      close(fd)
      throw ServerError.bindFailed(code)
    }
    guard listen(fd, 16) == 0 else {
      let code = errno
      close(fd)
      throw ServerError.listenFailed(code)
    }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }

    socketFD = fd
    port = UInt16(bigEndian: bound.sin_port)
    self.handler = handler
    self.onFailure = onFailure

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
  }

  deinit { stop() }

  /// Idempotent, thread-safe. Closing the socket unblocks accept().
  func stop() {
    lock.lock()
    let already = isStopped
    isStopped = true
    lock.unlock()
    if !already {
      shutdown(socketFD, SHUT_RDWR)
      close(socketFD)
    }
  }

  private var stopped: Bool {
    lock.lock(); defer { lock.unlock() }
    return isStopped
  }

  // MARK: - Accept

  private func acceptLoop() {
    while !stopped {
      let client = accept(socketFD, nil, nil)
      if client < 0 {
        if stopped { return }
        if errno == EINTR || errno == ECONNABORTED { continue }
        if errno == EMFILE || errno == ENFILE {
          // Too many open files system-wide: wait for some to close rather than spin or give up.
          usleep(100_000)
          continue
        }
        onFailure("accept failed (errno \(errno): \(String(cString: strerror(errno))))")
        return
      }
      guard connectionSemaphore.wait(timeout: .now()) == .success else {
        // At the concurrency cap: reject fast instead of queuing behind in-flight connections.
        write(client, HTTPResponse.json(["error": "busy"], status: 503))
        close(client)
        continue
      }
      workQueue.async { [weak self] in
        defer { self?.connectionSemaphore.signal() }
        self?.serve(client)
        close(client)
      }
    }
  }

  private func serve(_ client: Int32) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    // SO_RCVTIMEO only bounds a single recv(); a client that trickles bytes slowly (one byte every
    // 4s) would otherwise hold this thread indefinitely. This caps the whole read phase instead.
    // Monotonic clock so a wall-clock jump (sleep/wake, NTP) can't extend or cut it short.
    let deadline = DispatchTime.now() + .seconds(10)
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    var request: HTTPRequest?
    while request == nil {
      switch Self.parse(buffer) {
      case .complete(let r):
        request = r
      case .tooLarge:
        write(client, HTTPResponse.json(["error": "request too large"], status: 413))
        return
      case .malformed:
        write(client, HTTPResponse.json(["error": "bad request"], status: 400))
        return
      case .incomplete:
        if DispatchTime.now() >= deadline { return }  // too slow — drop without a response
        let n = recv(client, &chunk, chunk.count, 0)
        if n <= 0 { return }  // closed or timed out
        buffer.append(chunk, count: n)
      }
    }
    guard let request else { return }
    write(client, handler(request))
  }

  private func write(_ client: Int32, _ response: HTTPResponse) {
    var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
    head += "Content-Type: \(response.contentType)\r\n"
    head += "Content-Length: \(response.body.count)\r\n"
    head += "Connection: close\r\n"
    for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
    head += "\r\n"
    var data = Data(head.utf8)
    data.append(response.body)
    data.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let n = send(client, raw.baseAddress! + sent, raw.count - sent, 0)
        if n <= 0 { return }
        sent += n
      }
    }
  }

  static func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 202: return "Accepted"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 413: return "Payload Too Large"
    default: return "Status"
    }
  }

  // MARK: - Parsing (pure)

  static func parse(_ data: Data) -> ParseResult {
    let terminator = Data("\r\n\r\n".utf8)
    guard let headerEnd = data.range(of: terminator) else {
      return data.count > maxHeaderBytes ? .tooLarge : .incomplete
    }
    guard let headText = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
      return .malformed
    }
    let lines = headText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .malformed }
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return .malformed }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }

    var contentLength = 0
    if let raw = headers["content-length"] {
      guard let n = Int(raw), n >= 0 else { return .malformed }
      contentLength = n
    }
    if contentLength > maxBodyBytes { return .tooLarge }

    let bodyStart = headerEnd.upperBound
    guard data.endIndex - bodyStart >= contentLength else { return .incomplete }
    let body = Data(data[bodyStart..<(bodyStart + contentLength)])

    var path = String(parts[1])
    if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }
    return .complete(HTTPRequest(method: String(parts[0]).uppercased(), path: path, headers: headers, body: body))
  }
}
