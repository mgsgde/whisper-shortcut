import Foundation

/// User-defined chat commands: one Markdown file per command in `UserContext/commands/`.
/// See `plans/active/user-commands.md`.

enum UserCommandScope: String {
  case meeting, chat, both
}

struct UserCommand: Equatable, Identifiable {
  /// Lowercase, no slash.
  let name: String
  let label: String
  let description: String
  let scope: UserCommandScope
  let body: String
  let fileURL: URL

  var id: String { name }
  var slash: String { "/" + name }
  var showsInMeeting: Bool { scope == .meeting || scope == .both }
  var showsInChat: Bool { scope == .chat || scope == .both }
}

struct UserCommandIssue: Equatable, Identifiable {
  let fileName: String
  let message: String
  /// True when the command was loaded anyway (e.g. unknown scope fell back to `both`).
  let isWarning: Bool

  var id: String { fileName + "|" + message }
}

enum UserCommandParser {
  static let maxFileBytes = 32 * 1024
  static let maxDescriptionLength = 80

  /// Lowercase letters, digits and dashes, at most 40 characters, not starting with a dash.
  static func isValidName(_ name: String) -> Bool {
    name.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil
  }

  static func parse(
    fileName: String,
    contents: String,
    reservedNames: Set<String>,
    fileURL: URL? = nil
  ) -> (command: UserCommand?, issues: [UserCommandIssue]) {
    func fail(_ message: String) -> (command: UserCommand?, issues: [UserCommandIssue]) {
      (nil, [UserCommandIssue(fileName: fileName, message: message, isWarning: false)])
    }

    let stem = (fileName as NSString).deletingPathExtension.lowercased()
    guard isValidName(stem) else {
      return fail(String(localized: "Invalid name. Use lowercase letters, digits and dashes (max 40 characters)."))
    }
    if reservedNames.contains(stem) {
      return fail("/\(stem) is a built-in command")
    }
    if contents.utf8.count > maxFileBytes {
      return fail(String(localized: "File is larger than 32 KB"))
    }

    var text = contents
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

    var issues: [UserCommandIssue] = []
    var meta: [String: String] = [:]
    var body = text

    let lines = text.components(separatedBy: "\n")
    if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---",
      let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
    {
      for line in lines[1..<close] {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, !key.hasPrefix("#") else { continue }
        meta[key] = unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
      }
      body = lines[(close + 1)...].joined(separator: "\n")
    }
    body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return fail(String(localized: "The command text is empty")) }

    var scope = UserCommandScope.both
    if let raw = meta["scope"], !raw.isEmpty {
      if let parsed = UserCommandScope(rawValue: raw.lowercased()) {
        scope = parsed
      } else {
        issues.append(
          UserCommandIssue(
            fileName: fileName,
            message: String(localized: "Unknown scope \"\(raw)\" (use meeting, chat or both); using both"),
            isWarning: true))
      }
    }

    let label: String
    if let l = meta["label"], !l.isEmpty {
      label = l
    } else {
      let spaced = stem.replacingOccurrences(of: "-", with: " ")
      label = spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    let description: String
    if let d = meta["description"], !d.isEmpty {
      description = d
    } else {
      let firstLine = body.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty } ?? ""
      var cleaned = firstLine
      while let c = cleaned.first, c == "#" || c == " " { cleaned.removeFirst() }
      description =
        cleaned.count > maxDescriptionLength
        ? String(cleaned.prefix(maxDescriptionLength)) + "…" : cleaned
    }

    let command = UserCommand(
      name: stem, label: label, description: description, scope: scope, body: body,
      fileURL: fileURL ?? URL(fileURLWithPath: "/" + fileName))
    return (command, issues)
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2, let f = value.first, let l = value.last,
      (f == "\"" && l == "\"") || (f == "'" && l == "'")
    else { return value }
    return String(value.dropFirst().dropLast())
  }

  /// Text typed after the command name is appended as extra instructions.
  static func appendingArguments(_ body: String, arguments: String) -> String {
    let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    return args.isEmpty ? body : body + "\n\nAdditional instructions: " + args
  }
}

final class UserCommandStore: ObservableObject {
  static let shared = UserCommandStore(
    directoryURL: AppSupportPaths.userContextURL().appendingPathComponent("commands"),
    reservedNames: { ChatViewModel.reservedUserCommandNames })

  @Published private(set) var commands: [UserCommand] = []
  @Published private(set) var issues: [UserCommandIssue] = []

  let directoryURL: URL
  private let reservedNames: @MainActor () -> Set<String>

  init(directoryURL: URL, reservedNames: @escaping @MainActor () -> Set<String> = { [] }) {
    self.directoryURL = directoryURL
    self.reservedNames = reservedNames
  }

  func command(named name: String) -> UserCommand? {
    let key = name.lowercased()
    return commands.first { $0.name == key }
  }

  /// Reads the folder synchronously (a handful of small files). Never throws.
  func reload() {
    let loaded = loadFromDisk()
    let apply = {
      self.commands = loaded.commands
      self.issues = loaded.issues
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.sync(execute: apply) }
    let meeting = loaded.commands.filter(\.showsInMeeting).count
    DebugLogger.log(
      "USER-COMMANDS: loaded \(loaded.commands.count) (meeting \(meeting)) from \(directoryURL.path), issues \(loaded.issues.count)"
    )
  }

  private func loadFromDisk() -> (commands: [UserCommand], issues: [UserCommandIssue]) {
    AppSupportPaths.ensureDirectoryExists(directoryURL)
    let fm = FileManager.default
    var found: [UserCommand] = []
    var problems: [UserCommandIssue] = []
    let provider = reservedNames
    let reserved: Set<String> =
      Thread.isMainThread
      ? MainActor.assumeIsolated { provider() }
      : DispatchQueue.main.sync { MainActor.assumeIsolated { provider() } }

    let urls: [URL]
    do {
      urls = try fm.contentsOfDirectory(
        at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    } catch {
      return ([], [UserCommandIssue(fileName: directoryURL.lastPathComponent, message: error.localizedDescription, isWarning: false)])
    }
    for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let fileName = url.lastPathComponent
      guard !fileName.hasPrefix("."), url.pathExtension.lowercased() == "md" else { continue }
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { continue }
      do {
        let data = try Data(contentsOf: url)
        if data.count > UserCommandParser.maxFileBytes {
          problems.append(UserCommandIssue(fileName: fileName, message: String(localized: "File is larger than 32 KB"), isWarning: false))
          continue
        }
        guard let text = String(data: data, encoding: .utf8) else {
          problems.append(UserCommandIssue(fileName: fileName, message: String(localized: "File is not valid UTF-8 text"), isWarning: false))
          continue
        }
        let result = UserCommandParser.parse(
          fileName: fileName, contents: text, reservedNames: reserved, fileURL: url)
        problems.append(contentsOf: result.issues)
        if let cmd = result.command { found.append(cmd) }
      } catch {
        problems.append(UserCommandIssue(fileName: fileName, message: error.localizedDescription, isWarning: false))
      }
    }
    // Two files can only share a name if they differ in case; keep the first.
    var seen = Set<String>()
    found = found.filter { seen.insert($0.name).inserted }
    found.sort { $0.name < $1.name }
    return (found, problems)
  }

  static let templateContents = """
    ---
    # label: the button text in the meeting bar
    label: Meeting minutes
    # description: the subtitle in the command list and the button tooltip
    description: Write the meeting minutes in a fixed format
    # scope: meeting (meeting chats only), chat (normal chats only) or both
    scope: meeting
    ---
    Write the minutes of this meeting from the transcript. Use exactly these sections:

    ## Attendees
    ## Topics
    ## Decisions
    ## Action items (who, what, by when)

    Keep it short and factual. Do not add anything that was not said.
    """

  /// Moves a command file to the Trash (recoverable, unlike a hard delete) and re-reads the folder.
  /// Returns where the file landed so the caller can offer Undo.
  @discardableResult
  func moveToTrash(_ fileURL: URL) throws -> URL? {
    var trashed: NSURL?
    try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashed)
    DebugLogger.log("USER-COMMANDS: moved \(fileURL.lastPathComponent) to the Trash")
    reload()
    return trashed as URL?
  }

  /// Undo for `moveToTrash`: puts the file back under its original name.
  func restore(from trashedURL: URL, to originalURL: URL) throws {
    try FileManager.default.moveItem(at: trashedURL, to: originalURL)
    DebugLogger.log("USER-COMMANDS: restored \(originalURL.lastPathComponent) from the Trash")
    reload()
  }

  enum SaveError: LocalizedError {
    case invalidName, reserved(String), emptyText, tooLarge

    var errorDescription: String? {
      switch self {
      case .invalidName: return String(localized: "Invalid name. Use lowercase letters, digits and dashes (max 40 characters).")
      case .reserved(let n): return String(localized: "/\(n) is a built-in command")
      case .emptyText: return String(localized: "The command text is empty")
      case .tooLarge: return String(localized: "The command is larger than 32 KB")
      }
    }
  }

  /// Names the in-app Chat already uses.
  func reservedNameSet() -> Set<String> {
    let provider = reservedNames
    return Thread.isMainThread
      ? MainActor.assumeIsolated { provider() }
      : DispatchQueue.main.sync { MainActor.assumeIsolated { provider() } }
  }

  func fileURL(forName name: String) -> URL {
    directoryURL.appendingPathComponent("\(name).md")
  }

  /// The file text for a command: frontmatter the parser reads back, then the body.
  static func render(name: String, text: String, scope: UserCommandScope, label: String?, description: String?) -> String {
    func oneLine(_ s: String) -> String {
      s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }.joined(separator: " ")
    }
    var front = ["---", "scope: \(scope.rawValue)"]
    if let label, !oneLine(label).isEmpty { front.append("label: \(oneLine(label))") }
    if let description, !oneLine(description).isEmpty { front.append("description: \(oneLine(description))") }
    front.append("---")
    return front.joined(separator: "\n") + "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  /// Writes (or overwrites) `<name>.md` atomically, then re-reads the folder. Validates the name
  /// like the parser does and refuses built-in names.
  @discardableResult
  func save(
    name: String, text: String, scope: UserCommandScope, label: String? = nil, description: String? = nil
  ) throws -> URL {
    guard UserCommandParser.isValidName(name) else { throw SaveError.invalidName }
    guard !reservedNameSet().contains(name) else { throw SaveError.reserved(name) }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SaveError.emptyText }
    let rendered = Self.render(name: name, text: text, scope: scope, label: label, description: description)
    guard rendered.utf8.count <= UserCommandParser.maxFileBytes else { throw SaveError.tooLarge }
    AppSupportPaths.ensureDirectoryExists(directoryURL)
    let url = fileURL(forName: name)
    try Data(rendered.utf8).write(to: url, options: .atomic)
    DebugLogger.log("USER-COMMANDS: saved \(name).md (\(rendered.count) chars)")
    reload()
    return url
  }

  /// Writes `new-command.md` (or `new-command-2.md`, `-3`, …). Never overwrites an existing file.
  @discardableResult
  func createFromTemplate() throws -> URL {
    AppSupportPaths.ensureDirectoryExists(directoryURL)
    let data = Data((Self.templateContents + "\n").utf8)
    var n = 1
    while true {
      let name = n == 1 ? "new-command.md" : "new-command-\(n).md"
      let url = directoryURL.appendingPathComponent(name)
      do {
        try data.write(to: url, options: .withoutOverwriting)
        return url
      } catch let error as NSError
        where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError
      {
        n += 1
        if n > 999 { throw error }
      }
    }
  }
}
