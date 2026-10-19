import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("User commands")
struct UserCommandsTests {

  private func parse(_ file: String, _ text: String, reserved: Set<String> = []) -> (command: UserCommand?, issues: [UserCommandIssue]) {
    UserCommandParser.parse(fileName: file, contents: text, reservedNames: reserved)
  }

  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("uc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: - Parser

  @Test("Frontmatter is read, quotes stripped, unknown keys ignored")
  func frontmatter() {
    let text = "---\nlabel: \"My Report\"\ndescription: 'Short one'\nscope: meeting\nfoo: bar\n---\nDo the thing.\n"
    let r = parse("report.md", text)
    #expect(r.issues.isEmpty)
    #expect(r.command?.label == "My Report")
    #expect(r.command?.description == "Short one")
    #expect(r.command?.scope == .meeting)
    #expect(r.command?.body == "Do the thing.")
    #expect(r.command?.slash == "/report")
    #expect(r.command?.showsInMeeting == true)
    #expect(r.command?.showsInChat == false)
  }

  @Test("Without frontmatter the defaults apply")
  func defaults() {
    let long = String(repeating: "x", count: 100)
    let r = parse("Meeting-Minutes.md", "\n## \(long)\nsecond line")
    #expect(r.command?.name == "meeting-minutes")
    #expect(r.command?.label == "Meeting minutes")
    #expect(r.command?.scope == .both)
    #expect(r.command?.description == String(repeating: "x", count: 80) + "…")
    #expect(r.command?.body.hasPrefix("##") == true)
  }

  @Test("Unknown scope loads with a warning and falls back to both")
  func unknownScope() {
    let r = parse("a.md", "---\nscope: nowhere\n---\nBody")
    #expect(r.command?.scope == .both)
    #expect(r.issues.count == 1)
    #expect(r.issues.first?.isWarning == true)
  }

  @Test("Empty body is an error")
  func emptyBody() {
    let r = parse("a.md", "---\nlabel: X\n---\n   \n")
    #expect(r.command == nil)
    #expect(r.issues.first?.isWarning == false)
  }

  @Test("Invalid names are rejected")
  func invalidNames() {
    for file in ["Bad Name.md", "-x.md", "a_b.md", String(repeating: "a", count: 41) + ".md"] {
      let r = parse(file, "Body")
      #expect(r.command == nil, "\(file)")
      #expect(r.issues.count == 1)
    }
  }

  @Test("Built-in names and model aliases are reserved")
  @MainActor
  func reserved() {
    let reserved = ChatViewModel.reservedUserCommandNames
    #expect(reserved.contains("new"))
    #expect(reserved.contains("gemini"))
    for file in ["new.md", "gemini.md"] {
      let r = parse(file, "Body", reserved: reserved)
      #expect(r.command == nil)
      #expect(r.issues.first?.message.contains("built-in") == true)
    }
  }

  @Test("BOM and CRLF are tolerated")
  func bomAndCRLF() {
    let r = parse("a.md", "\u{FEFF}---\r\nlabel: L\r\nscope: chat\r\n---\r\nLine one\r\nLine two\r\n")
    #expect(r.command?.label == "L")
    #expect(r.command?.scope == .chat)
    #expect(r.command?.body == "Line one\nLine two")
  }

  @Test("Files over 32 KB are rejected")
  func sizeCap() {
    let r = parse("a.md", String(repeating: "a", count: 32 * 1024 + 1))
    #expect(r.command == nil)
    #expect(r.issues.count == 1)
  }

  @Test("Arguments are appended only when present")
  func arguments() {
    #expect(UserCommandParser.appendingArguments("Body", arguments: "  ") == "Body")
    #expect(UserCommandParser.appendingArguments("Body", arguments: "focus on X")
      == "Body\n\nAdditional instructions: focus on X")
  }

  // MARK: - Store

  @Test("Reload loads valid files and reports broken ones; non-md and hidden files are ignored")
  func storeReload() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "Alpha body".write(to: dir.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
    try "Beta body".write(to: dir.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
    try "".write(to: dir.appendingPathComponent("broken.md"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
    let store = UserCommandStore(directoryURL: dir, reservedNames: { ["new"] })
    store.reload()
    #expect(store.commands.map(\.name) == ["alpha", "beta"])
    #expect(store.issues.count == 1)
    #expect(store.issues.first?.fileName == "broken.md")
    #expect(store.command(named: "ALPHA")?.body == "Beta body")
  }

  @Test("createFromTemplate never overwrites and the template parses")
  func template() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = UserCommandStore(directoryURL: dir)
    let first = try store.createFromTemplate()
    let firstData = try Data(contentsOf: first)
    let second = try store.createFromTemplate()
    #expect(first != second)
    #expect(first.lastPathComponent == "new-command.md")
    #expect(second.lastPathComponent == "new-command-2.md")
    #expect(try Data(contentsOf: first) == firstData)
    let text = try String(contentsOf: first, encoding: .utf8)
    let r = UserCommandParser.parse(fileName: first.lastPathComponent, contents: text, reservedNames: [])
    #expect(r.command != nil)
    #expect(r.issues.isEmpty)
    #expect(r.command?.scope == .meeting)
  }

  // MARK: - ChatMessage

  @Test("ChatMessage commandName decodes nil from old JSON and round-trips")
  func chatMessageCommandName() throws {
    let plain = ChatMessage(role: .user, content: "hi")
    let enc = JSONEncoder()
    let data = try enc.encode(plain)
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("commandName"))
    let dec = JSONDecoder()
    #expect(try dec.decode(ChatMessage.self, from: data).commandName == nil)

    let withCommand = ChatMessage(role: .user, content: "hi", commandName: "report")
    let back = try dec.decode(ChatMessage.self, from: try enc.encode(withCommand))
    #expect(back.commandName == "report")
  }
}
