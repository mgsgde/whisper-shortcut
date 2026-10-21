import Foundation

/// One change an AI app made to the configuration (directly or through an accepted proposal).
struct MCPChange: Codable, Identifiable {
  enum Kind: String, Codable {
    case glossaryAdd, systemPrompt, writingStyle, saveCommand, deleteCommand
  }

  let id: String
  let appliedAt: Date
  let kind: Kind
  /// `SystemPromptSection` raw value, "profile" for the writing style, or the command name.
  let target: String
  /// nil = did not exist before.
  let previousContent: String?
  /// nil = deleted.
  let newContent: String?
  let rationale: String
  let viaProposal: Bool
  var undoneAt: Date?
}

enum MCPUndoResult: Equatable {
  case undone
  /// The target changed after the AI app's edit; nothing was written. Carries what is there now.
  case conflict(current: String?)
  case notFound
  case failed(String)
}

/// Append-only record of applied changes in `UserContext/mcp-changes.jsonl`, with Undo.
/// Never logs content; DebugLogger lines carry kinds, targets and lengths only.
final class MCPChangeLog: ObservableObject {
  static let shared = MCPChangeLog(
    directory: AppSupportPaths.userContextURL(), targets: .live)

  static let fileName = "mcp-changes.jsonl"
  static let maxChanges = 200

  /// Newest first. Mutated on main.
  @Published private(set) var changes: [MCPChange] = []

  let fileURL: URL
  var targets: MCPConfigTargets
  /// Writes the system prompts history. Injected so tests never touch the real UserContext.
  var recordHistory: (SystemPromptSection, Int, Int, String, String) -> Void

  init(
    directory: URL, targets: MCPConfigTargets,
    recordHistory: @escaping (SystemPromptSection, Int, Int, String, String) -> Void = {
      section, previousLength, newLength, content, source in
      ContextLogger.shared.appendSystemPromptsHistory(
        section: section, previousLength: previousLength, newLength: newLength, content: content,
        source: source)
    }
  ) {
    self.fileURL = directory.appendingPathComponent(Self.fileName)
    self.targets = targets
    self.recordHistory = recordHistory
    self.changes = Self.load(fileURL)
  }

  private static func decoder() -> JSONDecoder {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
  }

  private static func load(_ url: URL) -> [MCPChange] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let d = decoder()
    let all = text.components(separatedBy: .newlines).compactMap { line -> MCPChange? in
      guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
      return try? d.decode(MCPChange.self, from: data)
    }
    // The file is oldest first (append order); ties in the one-second timestamps keep that order.
    return Array(all.reversed().prefix(maxChanges))
  }

  private func persist() {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    let lines = changes.reversed().compactMap { c -> String? in
      (try? e.encode(c)).flatMap { String(data: $0, encoding: .utf8) }
    }
    do {
      AppSupportPaths.ensureDirectoryExists(fileURL.deletingLastPathComponent())
      try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    } catch {
      DebugLogger.logError("MCP-CONFIG: could not write change log: \(error.localizedDescription)")
    }
  }

  /// Appends an applied change. Runs on main.
  @discardableResult
  func record(
    kind: MCPChange.Kind, target: String, previous: String?, new: String?, rationale: String,
    viaProposal: Bool
  ) -> MCPChange {
    MCPMain.run {
      let change = MCPChange(
        id: UUID().uuidString, appliedAt: Date(), kind: kind, target: target,
        previousContent: previous, newContent: new, rationale: rationale,
        viaProposal: viaProposal, undoneAt: nil)
      changes.insert(change, at: 0)
      if changes.count > Self.maxChanges { changes.removeLast(changes.count - Self.maxChanges) }
      persist()
      if let section = historySection(kind: kind, target: target), let new {
        recordHistory(section, previous?.count ?? 0, new.count, new, "mcp")
      }
      DebugLogger.log(
        "MCP-CONFIG: change \(kind.rawValue) \(target) recorded len=\(new?.count ?? 0) viaProposal=\(viaProposal)")
      return change
    }
  }

  private func historySection(kind: MCPChange.Kind, target: String) -> SystemPromptSection? {
    switch kind {
    case .glossaryAdd: return .whisperGlossary
    case .systemPrompt: return SystemPromptSection(rawValue: target)
    default: return nil
    }
  }

  /// Restores the previous content, but only if the target still holds what the AI app wrote.
  func undo(_ id: String) -> MCPUndoResult {
    MCPMain.run {
      guard let index = changes.firstIndex(where: { $0.id == id && $0.undoneAt == nil }) else {
        return .notFound
      }
      let change = changes[index]
      let current = targets.current(kind: change.kind, target: change.target)
      guard MCPConfigTargets.normalized(current) == MCPConfigTargets.normalized(change.newContent) else {
        DebugLogger.log("MCP-CONFIG: undo \(change.kind.rawValue) \(change.target) rejected (changed since)")
        return .conflict(current: current)
      }
      do {
        try restore(change)
      } catch {
        DebugLogger.logError("MCP-CONFIG: undo \(change.kind.rawValue) \(change.target) failed: \(error.localizedDescription)")
        return .failed(error.localizedDescription)
      }
      changes[index].undoneAt = Date()
      persist()
      if let section = historySection(kind: change.kind, target: change.target) {
        let restored = change.previousContent ?? ""
        recordHistory(section, change.newContent?.count ?? 0, restored.count, restored, "mcp-undo")
      }
      DebugLogger.log("MCP-CONFIG: undo \(change.kind.rawValue) \(change.target) applied")
      return .undone
    }
  }

  private func restore(_ change: MCPChange) throws {
    switch change.kind {
    case .glossaryAdd:
      guard targets.systemPrompts.updateSection(.whisperGlossary, content: change.previousContent ?? "") else {
        throw MCPConfigError(message: "Could not write the glossary.")
      }
    case .systemPrompt:
      guard let section = SystemPromptSection(rawValue: change.target),
        targets.systemPrompts.updateSection(section, content: change.previousContent ?? "")
      else { throw MCPConfigError(message: "Could not write the section.") }
    case .writingStyle:
      targets.writingStyle.saveProfile(change.previousContent ?? "")
    case .saveCommand, .deleteCommand:
      let url = targets.commands.fileURL(forName: change.target)
      if let previous = change.previousContent {
        AppSupportPaths.ensureDirectoryExists(targets.commands.directoryURL)
        try Data(previous.utf8).write(to: url, options: .atomic)
        targets.commands.reload()
      } else {
        // The AI app created this file; trash it, and if the Trash is unavailable remove it
        // (the text stays in this change's newContent).
        do { try targets.commands.moveToTrash(url) } catch {
          try FileManager.default.removeItem(at: url)
          targets.commands.reload()
        }
      }
    }
  }
}
