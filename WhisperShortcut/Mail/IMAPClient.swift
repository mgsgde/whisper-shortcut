import Foundation
import Network

// Read-only IMAP over implicit TLS (port 993). The client sends EXAMINE and BODY.PEEK only:
// never SELECT, STORE, EXPUNGE, COPY, MOVE, or APPEND, and never STARTTLS or plaintext.

protocol IMAPTransport: Sendable {
  func open() async throws
  func write(_ data: Data) async throws
  /// Next chunk from the server. Empty data means the connection closed.
  func read() async throws -> Data
  func close()
}

enum IMAPError: LocalizedError, Equatable, Sendable {
  case authenticationFailed
  case connectionFailed(String)
  case tlsFailed
  case timeout
  case unsupportedPassword
  /// NO/BAD text from the server, with any password removed.
  case server(String)
  case protocolError(String)

  var errorDescription: String? {
    switch self {
    case .authenticationFailed:
      return "The server rejected the email address or password."
    case .connectionFailed(let host):
      return "Couldn't reach \(host). Check the server name."
    case .tlsFailed:
      return "The secure connection to the mail server failed."
    case .timeout:
      return "The mail server did not respond in time."
    case .unsupportedPassword:
      return "The password contains a line break."
    case .server(let text):
      return text
    case .protocolError(let text):
      return text
    }
  }
}

struct IMAPMessageSummary: Sendable, Equatable {
  var uid: Int
  var date: String
  var from: String
  var subject: String
  var unread: Bool
  var size: Int
}

final class NWIMAPTransport: IMAPTransport, @unchecked Sendable {
  private let host: String
  private let connection: NWConnection?
  private let openError: IMAPError?
  private let queue = DispatchQueue(label: "com.whispershortcut.imap")

  init(host: String, port: Int) {
    self.host = host
    guard port > 0, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
      connection = nil
      openError = .connectionFailed(host.isEmpty ? "the mail server" : host)
      return
    }
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = 20
    let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
    connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    openError = nil
  }

  func open() async throws {
    if let openError { throw openError }
    guard let connection else { throw IMAPError.connectionFailed(host) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeOnce()
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          if once.claim() { continuation.resume() }
        case .waiting(let error):
          if case .dns = error, once.claim() {
            connection.cancel()
            continuation.resume(throwing: IMAPError.connectionFailed(self.displayedHost))
          }
        case .failed(let error):
          if once.claim() { continuation.resume(throwing: self.map(error)) }
        case .cancelled:
          if once.claim() { continuation.resume(throwing: IMAPError.connectionFailed(self.displayedHost)) }
        default:
          break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + 20) {
        if once.claim() {
          connection.cancel()
          continuation.resume(throwing: IMAPError.timeout)
        }
      }
    }
  }

  func write(_ data: Data) async throws {
    guard let connection else { throw IMAPError.connectionFailed(displayedHost) }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let once = ResumeOnce()
        connection.send(content: data, isComplete: false, completion: .contentProcessed { [weak self] error in
          guard let self else { return }
          if let error {
            if once.claim() { continuation.resume(throwing: self.map(error)) }
          } else if once.claim() {
            continuation.resume()
          }
        })
      }
    } onCancel: {
      connection.cancel()
    }
  }

  func read() async throws -> Data {
    guard let connection else { throw IMAPError.connectionFailed(displayedHost) }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        let once = ResumeOnce()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
          guard let self else { return }
          if let error {
            if once.claim() { continuation.resume(throwing: self.map(error)) }
            return
          }
          if let data, !data.isEmpty {
            if once.claim() { continuation.resume(returning: data) }
            return
          }
          if once.claim() { continuation.resume(returning: isComplete ? Data() : Data()) }
        }
      }
    } onCancel: {
      connection.cancel()
    }
  }

  func close() {
    connection?.cancel()
  }

  private var displayedHost: String { host.isEmpty ? "the mail server" : host }

  private func map(_ error: NWError) -> IMAPError {
    switch error {
    case .tls:
      return .tlsFailed
    case .dns:
      return .connectionFailed(displayedHost)
    case .posix(let code) where code == .ETIMEDOUT:
      return .timeout
    case .posix:
      return .connectionFailed(displayedHost)
    @unknown default:
      return .connectionFailed(displayedHost)
    }
  }
}

actor IMAPSession {
  private let transport: IMAPTransport
  private let host: String
  private var buffer = Data()
  private var tagCounter = 0
  /// Values that must never appear in a log line or an error string.
  private var secrets: [String] = []

  private static let commandTimeout: Duration = .seconds(20)
  private static let maxLiteralBytes = 2_000_000

  init(transport: IMAPTransport, host: String = "") {
    self.transport = transport
    self.host = host
  }

  func login(user: String, password: String) async throws {
    try Self.rejectLineBreaks(user: user, password: password)
    secrets = [password]
    DebugLogger.log("IMAP: connecting host=\(host.isEmpty ? "?" : host)")
    let greeting = try await readResponse(before: Self.deadline())
    try checkGreeting(greeting)
    let caps = try await run([.text(" CAPABILITY")], authenticating: false)
    let blob = caps.map(\.textJoined).joined(separator: " ").uppercased()
    if blob.contains("AUTH=PLAIN") && blob.contains("SASL-IR") {
      let token = Self.saslPlain(user: user, password: password)
      secrets.append(token)
      try await run([.text(" AUTHENTICATE PLAIN \(token)")], authenticating: true)
    } else {
      try await run(Self.loginPieces(user: user, password: password), authenticating: true)
    }
  }

  func listMailboxes() async throws -> [String] {
    let responses = try await run([.text(" LIST \"\" \"*\"")], authenticating: false)
    var names: [String] = []
    for response in responses {
      if let name = mailboxName(in: response) {
        names.append(name)
      }
    }
    return names
  }

  func examine(_ mailbox: String) async throws -> Int {
    let responses = try await run(
      [.text(" EXAMINE "), mailboxPiece(mailbox)], authenticating: false)
    var count = 0
    for response in responses {
      let tokens = Self.imapTokens(response.textJoined)
      if tokens.count >= 3, tokens[0] == "*", tokens[2].uppercased() == "EXISTS",
         let n = Int(tokens[1]) {
        count = n
      }
    }
    return count
  }

  func uidSearch(from: String? = nil, subject: String? = nil, text: String? = nil, since: Date? = nil) async throws -> [Int] {
    let pieces = searchPieces(from: from, subject: subject, text: text, since: since)
    let responses = try await run(pieces, authenticating: false)
    var uids: [Int] = []
    for response in responses {
      let tokens = Self.imapTokens(response.textJoined)
      guard tokens.count >= 2, tokens[0] == "*", tokens[1].uppercased() == "SEARCH" else { continue }
      for token in tokens.dropFirst(2) {
        if let n = Int(token) { uids.append(n) }
      }
    }
    return uids
  }

  func fetchHeaders(uids: [Int]) async throws -> [IMAPMessageSummary] {
    guard !uids.isEmpty else { return [] }
    let set = uids.map(String.init).joined(separator: ",")
    let responses = try await run(
      [.text(" UID FETCH \(set) (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE)])")],
      authenticating: false)
    try rejectOversized(responses)
    var byUID: [Int: IMAPMessageSummary] = [:]
    for response in responses {
      guard let summary = parseHeaderFetch(response) else { continue }
      byUID[summary.uid] = summary
    }
    return uids.compactMap { byUID[$0] }
  }

  func fetchBody(uid: Int) async throws -> Data {
    let responses = try await run(
      [.text(" UID FETCH \(uid) (UID FLAGS BODY.PEEK[])")],
      authenticating: false)
    try rejectOversized(responses)
    for response in responses {
      guard response.textJoined.uppercased().contains("FETCH"), let literal = response.literals.last else { continue }
      return literal
    }
    throw IMAPError.protocolError("The mail server did not return the message.")
  }

  func logout() async {
    do {
      _ = try await run([.text(" LOGOUT")], authenticating: false)
    } catch {
      DebugLogger.log("IMAP: logout ended")
    }
  }

  // MARK: - Commands

  private enum Piece: Sendable {
    case text(String)
    case literal(Data)
  }

  private struct ServerResponse: Sendable {
    enum Segment: Sendable {
      case text(String)
      case literal(Data)
    }
    var segments: [Segment]
    var oversized = false

    var textJoined: String {
      segments.compactMap { segment -> String? in
        if case .text(let text) = segment { return text }
        return nil
      }.joined()
    }

    var literals: [Data] {
      segments.compactMap { segment -> Data? in
        if case .literal(let data) = segment { return data }
        return nil
      }
    }

    var opening: String {
      if case .text(let text) = segments.first { return text }
      return textJoined
    }
  }

  private func run(_ pieces: [Piece], authenticating: Bool) async throws -> [ServerResponse] {
    let deadline = Self.deadline()
    let tag = nextTag()
    try await send(tag: tag, pieces: pieces, before: deadline, authenticating: authenticating)
    return try await collect(tag: tag, before: deadline, authenticating: authenticating)
  }

  private func nextTag() -> String {
    tagCounter += 1
    return String(format: "A%03d", tagCounter)
  }

  private func send(tag: String, pieces: [Piece], before deadline: ContinuousClock.Instant, authenticating: Bool) async throws {
    logCommand(tag: tag, pieces: pieces)
    var pending = Data(tag.utf8)
    for piece in pieces {
      switch piece {
      case .text(let text):
        pending.append(Data(text.utf8))
      case .literal(let data):
        pending.append(Data("{\(data.count)}\r\n".utf8))
        try await writeChunk(pending, before: deadline)
        pending.removeAll(keepingCapacity: true)
        try await readContinuation(tag: tag, before: deadline, authenticating: authenticating)
        try await writeChunk(data, before: deadline)
      }
    }
    pending.append(Data("\r\n".utf8))
    try await writeChunk(pending, before: deadline)
  }

  private func collect(tag: String, before deadline: ContinuousClock.Instant, authenticating: Bool) async throws -> [ServerResponse] {
    var items: [ServerResponse] = []
    while true {
      let response = try await readResponse(before: deadline)
      logResponse(response, tag: tag)
      let opening = response.opening.trimmingCharacters(in: .whitespacesAndNewlines)
      if opening.isEmpty { continue }
      if opening.hasPrefix("+") {
        throw IMAPError.protocolError("Unexpected continuation from the mail server.")
      }
      if Self.hasTag(opening, tag: tag) {
        try finishTagged(opening, tag: tag, authenticating: authenticating)
        return items
      }
      items.append(response)
    }
  }

  private func readContinuation(tag: String, before deadline: ContinuousClock.Instant, authenticating: Bool) async throws {
    while true {
      let response = try await readResponse(before: deadline)
      logResponse(response, tag: tag)
      let opening = response.opening.trimmingCharacters(in: .whitespacesAndNewlines)
      if opening.hasPrefix("+") { return }
      if Self.hasTag(opening, tag: tag) {
        try finishTagged(opening, tag: tag, authenticating: authenticating)
        throw IMAPError.protocolError("Expected a continuation from the mail server.")
      }
      if opening.uppercased().hasPrefix("* BYE") {
        throw IMAPError.protocolError("The server closed the connection.")
      }
    }
  }

  private func finishTagged(_ opening: String, tag: String, authenticating: Bool) throws {
    let rest = opening.dropFirst(tag.count).trimmingCharacters(in: .whitespacesAndNewlines)
    let upper = rest.uppercased()
    if upper.hasPrefix("OK") { return }
    if upper.hasPrefix("NO") || upper.hasPrefix("BAD") {
      if authenticating { throw IMAPError.authenticationFailed }
      throw IMAPError.server(scrub(String(rest)))
    }
    throw IMAPError.protocolError("Unexpected response from the mail server.")
  }

  private func checkGreeting(_ response: ServerResponse) throws {
    let opening = response.opening.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard opening.hasPrefix("* OK") || opening.hasPrefix("* PREAUTH") else {
      throw IMAPError.protocolError("Unexpected greeting from the mail server.")
    }
  }

  // MARK: - Reader

  private func readResponse(before deadline: ContinuousClock.Instant) async throws -> ServerResponse {
    var segments: [ServerResponse.Segment] = []
    var oversized = false
    while true {
      let line = try await readLine(before: deadline)
      if let split = Self.literalSuffix(line) {
        if !split.text.isEmpty {
          segments.append(.text(split.text))
        }
        if split.count > Self.maxLiteralBytes {
          try await discard(split.count, before: deadline)
          oversized = true
        } else {
          let literal = try await readExact(split.count, before: deadline)
          segments.append(.literal(literal))
        }
        continue
      }
      segments.append(.text(line))
      return ServerResponse(segments: segments, oversized: oversized)
    }
  }

  private func readLine(before deadline: ContinuousClock.Instant) async throws -> String {
    let crlf = Data([13, 10])
    while buffer.range(of: crlf) == nil {
      try await fill(before: deadline)
    }
    guard let range = buffer.range(of: crlf) else {
      throw IMAPError.protocolError("Expected a line from the mail server.")
    }
    let line = Data(buffer[..<range.lowerBound])
    buffer.removeSubrange(..<range.upperBound)
    return String(decoding: line, as: UTF8.self)
  }

  private func readExact(_ count: Int, before deadline: ContinuousClock.Instant) async throws -> Data {
    while buffer.count < count {
      try await fill(before: deadline)
    }
    let data = Data(buffer.prefix(count))
    buffer.removeFirst(count)
    return data
  }

  private func discard(_ count: Int, before deadline: ContinuousClock.Instant) async throws {
    var left = count
    while left > 0 {
      if buffer.isEmpty { try await fill(before: deadline) }
      let drop = min(left, buffer.count)
      buffer.removeFirst(drop)
      left -= drop
    }
    DebugLogger.log("IMAP: discarded literal bytes=\(count)")
  }

  private func fill(before deadline: ContinuousClock.Instant) async throws {
    let chunk = try await readChunk(before: deadline)
    if chunk.isEmpty {
      throw IMAPError.protocolError("The server closed the connection.")
    }
    buffer.append(chunk)
  }

  private func readChunk(before deadline: ContinuousClock.Instant) async throws -> Data {
    let transport = self.transport
    return try await race(before: deadline) {
      try await transport.read()
    }
  }

  private func writeChunk(_ data: Data, before deadline: ContinuousClock.Instant) async throws {
    let transport = self.transport
    try await race(before: deadline) {
      try await transport.write(data)
    }
  }

  private enum RaceResult<T: Sendable>: Sendable {
    case value(T)
    case timedOut
    case cancelled
    case failed(IMAPError)
  }

  private func race<T: Sendable>(
    before deadline: ContinuousClock.Instant,
    _ operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    if ContinuousClock.now >= deadline { throw IMAPError.timeout }
    return try await withThrowingTaskGroup(of: RaceResult<T>.self) { group in
      group.addTask {
        do {
          return .value(try await operation())
        } catch is CancellationError {
          return .cancelled
        } catch let error as IMAPError {
          return .failed(error)
        } catch {
          return .failed(.protocolError("The mail server request failed."))
        }
      }
      group.addTask {
        do {
          try await Task.sleep(until: deadline, clock: ContinuousClock())
          return .timedOut
        } catch is CancellationError {
          return .cancelled
        } catch {
          return .failed(.timeout)
        }
      }
      var decided: RaceResult<T>?
      while let next = try await group.next() {
        switch next {
        case .cancelled:
          continue
        case .value, .timedOut, .failed:
          if decided == nil {
            decided = next
            group.cancelAll()
          }
        }
      }
      switch decided {
      case .value(let value):
        return value
      case .failed(let error):
        throw error
      case .timedOut, .cancelled, .none:
        throw IMAPError.timeout
      }
    }
  }

  // MARK: - Encoding

  private func searchPieces(from: String?, subject: String?, text: String?, since: Date?) -> [Piece] {
    let terms: [(String, String)] = [
      ("FROM", from), ("SUBJECT", subject), ("TEXT", text),
    ].compactMap { pair in
      guard let value = pair.1, !value.isEmpty else { return nil }
      return (pair.0, value)
    }
    let nonASCII = terms.contains { Self.needsLiteral($0.1) }
    var pieces: [Piece] = [.text(nonASCII ? " UID SEARCH CHARSET UTF-8" : " UID SEARCH")]
    if terms.isEmpty && since == nil {
      pieces.append(.text(" ALL"))
      return pieces
    }
    for (key, value) in terms {
      pieces.append(.text(" \(key) "))
      pieces.append(Self.argument(value))
    }
    if let since {
      pieces.append(.text(" SINCE \(Self.imapDate(since))"))
    }
    return pieces
  }

  private func mailboxPiece(_ mailbox: String) -> Piece {
    if mailbox.compare("INBOX", options: .caseInsensitive) == .orderedSame {
      return .text("INBOX")
    }
    return .text(Self.quote(Self.encodeModifiedUTF7(mailbox)))
  }

  private func mailboxName(in response: ServerResponse) -> String? {
    if case .literal(let data) = response.segments.last {
      let name = String(decoding: data, as: UTF8.self)
      return Self.decodeModifiedUTF7(name)
    }
    let tokens = Self.imapTokens(response.textJoined)
    guard tokens.count >= 4, tokens[0] == "*", tokens[1].uppercased() == "LIST" else { return nil }
    guard let last = tokens.last, last.uppercased() != "NIL" else { return nil }
    return Self.decodeModifiedUTF7(last)
  }

  private func parseHeaderFetch(_ response: ServerResponse) -> IMAPMessageSummary? {
    let text = response.textJoined
    guard text.uppercased().contains("FETCH") else { return nil }
    guard let uid = Self.firstCapture(#"UID (\d+)"#, in: text).flatMap(Int.init) else { return nil }
    let flags = Self.firstCapture(#"FLAGS \(([^)]*)\)"#, in: text) ?? ""
    let unread = !flags.split(whereSeparator: \.isWhitespace).contains {
      $0.caseInsensitiveCompare("\\Seen") == .orderedSame
    }
    let size = Self.firstCapture(#"RFC822\.SIZE (\d+)"#, in: text).flatMap(Int.init)
      ?? response.literals.last?.count
      ?? 0
    let decoded = MIMEDecoder.decode(response.literals.last ?? Data())
    return IMAPMessageSummary(
      uid: uid, date: decoded.date, from: decoded.from, subject: decoded.subject,
      unread: unread, size: size)
  }

  private func rejectOversized(_ responses: [ServerResponse]) throws {
    if responses.contains(where: \.oversized) {
      throw IMAPError.protocolError("The message is larger than 2 MB.")
    }
  }

  private func logCommand(tag: String, pieces: [Piece]) {
    let blob = pieces.map { piece -> String in
      switch piece {
      case .text(let text): return text
      case .literal(let data): return "{\(data.count)}"
      }
    }.joined()
    let verb = blob.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if verb.hasPrefix("LOGIN") || verb.hasPrefix("AUTHENTICATE") {
      DebugLogger.log("IMAP: \(tag) LOGIN <redacted>")
      return
    }
    // Command verb only: SEARCH criteria and mailbox names are the user's data.
    let words = blob.split(separator: " ", maxSplits: 3).prefix(2).joined(separator: " ")
    DebugLogger.log("IMAP: \(tag) \(scrub(words))")
  }

  private func logResponse(_ response: ServerResponse, tag: String) {
    let opening = response.opening.trimmingCharacters(in: .whitespacesAndNewlines)
    if Self.hasTag(opening, tag: tag) {
      let rest = opening.dropFirst(tag.count).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      let status: String
      if rest.hasPrefix("OK") { status = "OK" }
      else if rest.hasPrefix("NO") { status = "NO" }
      else if rest.hasPrefix("BAD") { status = "BAD" }
      else { status = "TAGGED" }
      DebugLogger.log("IMAP: ← \(tag) \(status)")
      return
    }
    let bytes = response.literals.reduce(0) { $0 + $1.count }
    DebugLogger.log("IMAP: ← untagged literals=\(response.literals.count) bytes=\(bytes)")
  }

  private func scrub(_ text: String) -> String {
    var result = text
    for secret in secrets where !secret.isEmpty {
      result = result.replacingOccurrences(of: secret, with: "<redacted>")
    }
    return result
  }

  private static func deadline() -> ContinuousClock.Instant {
    ContinuousClock.now.advanced(by: commandTimeout)
  }

  private static func rejectLineBreaks(user: String, password: String) throws {
    if user.contains("\r") || user.contains("\n") || password.contains("\r") || password.contains("\n") {
      throw IMAPError.unsupportedPassword
    }
  }

  private static func saslPlain(user: String, password: String) -> String {
    var data = Data([0])
    data.append(Data(user.utf8))
    data.append(0)
    data.append(Data(password.utf8))
    return data.base64EncodedString()
  }

  private static func loginPieces(user: String, password: String) -> [Piece] {
    var pieces: [Piece] = [.text(" LOGIN ")]
    pieces.append(argument(user))
    pieces.append(.text(" "))
    pieces.append(argument(password))
    return pieces
  }

  private static func argument(_ string: String) -> Piece {
    if needsLiteral(string) { return .literal(Data(string.utf8)) }
    return .text(quote(string))
  }

  private static func needsLiteral(_ string: String) -> Bool {
    string.utf8.contains { $0 > 127 }
  }

  private static func quote(_ string: String) -> String {
    var out = "\""
    for character in string {
      if character == "\\" || character == "\"" { out.append("\\") }
      out.append(character)
    }
    out.append("\"")
    return out
  }

  private static func imapDate(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let parts = calendar.dateComponents([.day, .month, .year], from: date)
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    let monthIndex = max(1, min(12, parts.month ?? 1)) - 1
    return String(format: "%02d-%@-%04d", parts.day ?? 1, months[monthIndex], parts.year ?? 1970)
  }

  private static func hasTag(_ line: String, tag: String) -> Bool {
    guard line.hasPrefix(tag) else { return false }
    let rest = line.dropFirst(tag.count)
    return rest.first == nil || rest.first == " "
  }

  private static func literalSuffix(_ line: String) -> (text: String, count: Int)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasSuffix("}"), let open = line.lastIndex(of: "{"),
          let count = literalCount(trimmed) else { return nil }
    return (String(line[..<open]), count)
  }

  private static func literalCount(_ trimmed: String) -> Int? {
    guard trimmed.hasSuffix("}"), let open = trimmed.lastIndex(of: "{") else { return nil }
    let innerStart = trimmed.index(after: open)
    let innerEnd = trimmed.index(before: trimmed.endIndex)
    guard innerStart <= innerEnd else { return nil }
    var digits = trimmed[innerStart..<innerEnd]
    if digits.last == "+" { digits.removeLast() }
    guard !digits.isEmpty else { return nil }
    return Int(digits)
  }

  private static func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          let captured = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[captured])
  }

  private static func imapTokens(_ line: String) -> [String] {
    var tokens: [String] = []
    var index = line.startIndex
    while index < line.endIndex {
      while index < line.endIndex && line[index] == " " {
        index = line.index(after: index)
      }
      guard index < line.endIndex else { break }
      let character = line[index]
      if character == "(" {
        var depth = 0
        let start = index
        while index < line.endIndex {
          if line[index] == "(" { depth += 1 }
          if line[index] == ")" {
            depth -= 1
            index = line.index(after: index)
            if depth == 0 { break }
            continue
          }
          index = line.index(after: index)
        }
        tokens.append(String(line[start..<index]))
      } else if character == "\"" {
        index = line.index(after: index)
        var value = ""
        while index < line.endIndex {
          let next = line[index]
          index = line.index(after: index)
          if next == "\\", index < line.endIndex {
            value.append(line[index])
            index = line.index(after: index)
          } else if next == "\"" {
            break
          } else {
            value.append(next)
          }
        }
        tokens.append(value)
      } else {
        let start = index
        while index < line.endIndex && line[index] != " " {
          index = line.index(after: index)
        }
        tokens.append(String(line[start..<index]))
      }
    }
    return tokens
  }

  /// RFC 3501 §5.1.3 modified UTF-7.
  private static func decodeModifiedUTF7(_ string: String) -> String {
    var out = ""
    var index = string.startIndex
    while index < string.endIndex {
      if string[index] != "&" {
        out.append(string[index])
        index = string.index(after: index)
        continue
      }
      let next = string.index(after: index)
      if next == string.endIndex {
        out.append("&")
        break
      }
      if string[next] == "-" {
        out.append("&")
        index = string.index(after: next)
        continue
      }
      guard let end = string[next...].firstIndex(of: "-") else {
        out.append(string[index])
        index = next
        continue
      }
      var base64 = string[next..<end].replacingOccurrences(of: ",", with: "/")
      while base64.count % 4 != 0 { base64.append("=") }
      if let data = Data(base64Encoded: base64) {
        out += decodeUTF16BE(data)
      }
      index = string.index(after: end)
    }
    return out
  }

  private static func encodeModifiedUTF7(_ string: String) -> String {
    var out = ""
    var pending: [UInt16] = []
    func flush() {
      guard !pending.isEmpty else { return }
      var data = Data()
      for unit in pending {
        data.append(UInt8(unit >> 8))
        data.append(UInt8(unit & 0xFF))
      }
      let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "/", with: ",")
        .replacingOccurrences(of: "=", with: "")
      out += "&\(encoded)-"
      pending.removeAll(keepingCapacity: true)
    }
    for scalar in string.unicodeScalars {
      if scalar.value >= 0x20 && scalar.value <= 0x7E && scalar != "&" {
        flush()
        out.unicodeScalars.append(scalar)
      } else if scalar == "&" {
        flush()
        out += "&-"
      } else {
        for unit in String(scalar).utf16 {
          pending.append(unit)
        }
      }
    }
    flush()
    return out
  }

  private static func decodeUTF16BE(_ data: Data) -> String {
    var units: [UInt16] = []
    units.reserveCapacity(data.count / 2)
    let bytes = [UInt8](data)
    var index = 0
    while index + 1 < bytes.count {
      units.append((UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]))
      index += 2
    }
    return String(utf16CodeUnits: units, count: units.count)
  }
}

private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}
