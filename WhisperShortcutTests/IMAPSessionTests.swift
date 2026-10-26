import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("IMAP session")
struct IMAPSessionTests {
  @Test func authenticatePlain() async throws {
    let password = "s3cret"
    let user = "user@example.com"
    var token = Data([0])
    token.append(Data(user.utf8))
    token.append(0)
    token.append(Data(password.utf8))
    let transport = ScriptedTransport(chunks: [
      "* OK IMAP ready\r\n",
      "* CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR IDLE\r\n",
      "A001 OK CAPABILITY completed\r\n",
      "A002 OK AUTHENTICATE completed\r\n",
    ])
    let session = IMAPSession(transport: transport, host: "imap.example.test")
    try await session.login(user: user, password: password)
    let transcript = transport.transcript
    #expect(transcript.contains("A001 CAPABILITY\r\n"))
    #expect(transcript.contains("A002 AUTHENTICATE PLAIN \(token.base64EncodedString())\r\n"))
    #expect(!transcript.contains(password))
  }

  @Test func loginQuotesBackslashAndQuote() async throws {
    let password = "p\"a\\b"
    let transport = ScriptedTransport(chunks: [
      "* OK IMAP ready\r\n",
      "* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n",
      "A001 OK CAPABILITY completed\r\n",
      "A002 OK LOGIN completed\r\n",
    ])
    let session = IMAPSession(transport: transport, host: "imap.example.test")
    try await session.login(user: "user@example.com", password: password)
    let expected = "A002 LOGIN \"user@example.com\" \"p\\\"a\\\\b\"\r\n"
    #expect(transport.transcript.contains(expected))
    #expect(!transport.transcript.contains("AUTHENTICATE"))
  }

  @Test func authenticationFailureHidesPassword() async throws {
    let password = "super-secret-pw"
    let transport = ScriptedTransport(chunks: [
      "* OK IMAP ready\r\n",
      "* CAPABILITY IMAP4rev1\r\n",
      "A001 OK CAPABILITY completed\r\n",
      "A002 NO [AUTHENTICATIONFAILED] \(password)\r\n",
    ])
    let session = IMAPSession(transport: transport, host: "imap.example.test")
    do {
      try await session.login(user: "user@example.com", password: password)
      Issue.record("login should fail")
    } catch let error as IMAPError {
      #expect(error == .authenticationFailed)
      #expect(error.localizedDescription == "The server rejected the email address or password.")
      #expect(!error.localizedDescription.contains(password))
      #expect(!String(describing: error).contains(password))
    }
  }

  @Test func listDecodesModifiedUTF7() async throws {
    let transport = ScriptedTransport(chunks: [
      "* LIST (\\HasNoChildren) \"/\" \"Entw&APw-rfe\"\r\n* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\nA001 OK LIST completed\r\n",
    ])
    let session = IMAPSession(transport: transport)
    let names = try await session.listMailboxes()
    #expect(names == ["Entwürfe", "INBOX"])
  }

  @Test func listResolvesLiteralFolderName() async throws {
    let transport = ScriptedTransport(chunks: [
      "* LIST (\\HasNoChildren) \"/\" {9}\r\nMy Folder\r\n* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\nA001 OK LIST completed\r\n",
    ])
    let session = IMAPSession(transport: transport)
    let names = try await session.listMailboxes()
    #expect(names == ["My Folder", "INBOX"])
  }

  @Test func slowButSteadyLiteralCompletes() async throws {
    var chunks: [String] = ["* 1 FETCH (UID 7 BODY[] {12}\r\n"]
    for part in ["Hello ", "World!"] { chunks.append(part) }
    chunks.append(")\r\nA001 OK FETCH completed\r\n")
    let transport = ScriptedTransport(chunks: chunks)
    let session = IMAPSession(transport: transport)
    let body = try await session.fetchBody(uid: 7)
    #expect(String(decoding: body, as: UTF8.self) == "Hello World!")
  }

  @Test func examineReadsExists() async throws {
    let transport = ScriptedTransport(chunks: [
      "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n* 1212 EXISTS\r\n* 0 RECENT\r\nA001 OK [READ-ONLY] EXAMINE completed\r\n",
    ])
    let session = IMAPSession(transport: transport)
    let count = try await session.examine("INBOX")
    #expect(count == 1212)
    #expect(transport.transcript.contains("EXAMINE INBOX\r\n"))
    #expect(!transport.transcript.contains("SELECT"))
  }

  @Test func uidSearchParsesIds() async throws {
    let transport = ScriptedTransport(chunks: [
      "* SEARCH 10 20 30\r\nA001 OK SEARCH completed\r\n",
    ])
    let session = IMAPSession(transport: transport)
    let uids = try await session.uidSearch()
    #expect(uids == [10, 20, 30])
    #expect(transport.transcript.contains("UID SEARCH ALL\r\n"))
  }

  @Test func tabIsLegalInAQuotedString() throws {
    // RFC 3501 TEXT-CHAR excludes only CR and LF, so a tab (e.g. in a password) must still pass.
    #expect(try IMAPSession.argument("a\tb") == .text("\"a\tb\""))
  }

  @Test func searchRejectsLineBreaks() {
    #expect(throws: IMAPError.self) {
      _ = try IMAPSession.searchPieces(
        from: nil, subject: "x\"\r\nA9 UID STORE 1 +FLAGS \\Deleted", text: nil, since: nil)
    }
    #expect(throws: IMAPError.self) {
      _ = try IMAPSession.searchPieces(from: "a\nb", subject: nil, text: nil, since: nil)
    }
  }

  @Test func searchKeepsNormalStringsUnchanged() throws {
    let pieces = try IMAPSession.searchPieces(from: nil, subject: "Rechnung \"X\"", text: nil, since: nil)
    #expect(pieces == [.text(" UID SEARCH"), .text(" SUBJECT "), .text("\"Rechnung \\\"X\\\"\"")])
  }

  @Test func fetchLiteralSplitAcrossReads() async throws {
    let header = Data("From: a@b.test\r\nSubject: Hi\r\n\r\n".utf8)
    let split = 10
    var first = Data("* 1 FETCH (UID 7 FLAGS (\\Seen) RFC822.SIZE \(header.count) BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE)] {\(header.count)}\r\n".utf8)
    first.append(header.prefix(split))
    var second = Data(header.suffix(from: split))
    second.append(Data(")\r\nA001 OK FETCH completed\r\n".utf8))
    let transport = ScriptedTransport(chunks: [first, second])
    let session = IMAPSession(transport: transport)
    let rows = try await session.fetchHeaders(uids: [7])
    #expect(rows.count == 1)
    #expect(rows[0].uid == 7)
    #expect(rows[0].from == "a@b.test")
    #expect(rows[0].subject == "Hi")
    #expect(rows[0].unread == false)
    #expect(rows[0].size == header.count)
    #expect(transport.transcript.contains("BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE)]"))
    #expect(!transport.transcript.contains("BODY["))
  }

  @Test func nonASCIISearchUsesCharsetAndClientLiteral() async throws {
    let term = "für"
    let transport = ScriptedTransport(chunks: [
      "+ go ahead\r\n",
      "* SEARCH 42\r\n",
      "A001 OK SEARCH completed\r\n",
    ])
    let session = IMAPSession(transport: transport)
    let uids = try await session.uidSearch(text: term)
    #expect(uids == [42])
    let writes = transport.writes.map { String(decoding: $0, as: UTF8.self) }
    #expect(writes[0].contains("CHARSET UTF-8"))
    #expect(writes[0].contains("{\(Data(term.utf8).count)}"))
    #expect(!writes[0].contains(term))
    let readAt = transport.marks.firstIndex(of: "R")
    let literalAt = transport.marks.firstIndex { $0.hasPrefix("W:") && $0.contains(term) }
    #expect(readAt != nil)
    #expect(literalAt != nil)
    #expect(readAt! < literalAt!)
  }
}

final class ScriptedTransport: IMAPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var reads: [Data]
  private(set) var writes: [Data] = []
  private(set) var marks: [String] = []

  init(chunks: [Data]) {
    reads = chunks
  }

  convenience init(chunks: [String]) {
    self.init(chunks: chunks.map { Data($0.utf8) })
  }

  func open() async throws {}

  func write(_ data: Data) async throws {
    lock.lock()
    writes.append(data)
    marks.append("W:" + String(decoding: data, as: UTF8.self))
    lock.unlock()
  }

  func read() async throws -> Data {
    try Task.checkCancellation()
    lock.lock()
    defer { lock.unlock() }
    marks.append("R")
    if reads.isEmpty { return Data() }
    return reads.removeFirst()
  }

  func close() {}

  var transcript: String {
    lock.lock()
    defer { lock.unlock() }
    return writes.map { String(decoding: $0, as: UTF8.self) }.joined()
  }
}
