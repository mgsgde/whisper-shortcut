import Foundation

/// Which configuration changes an AI app may make. Stored in `UserDefaultsKeys.mcpConfigAccessLevel`.
enum MCPConfigAccessLevel: String, CaseIterable {
  case read, propose, apply

  static var current: MCPConfigAccessLevel {
    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.mcpConfigAccessLevel) ?? ""
    return MCPConfigAccessLevel(rawValue: raw) ?? .read
  }
}

struct MCPConfigError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Every configuration write goes through one serial path: the main thread. `LoopbackHTTPServer`
/// calls handlers on a concurrent queue and the stores read-modify-write without a shared lock,
/// so two requests would otherwise lose an update.
enum MCPMain {
  static func run<T>(_ block: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try block() }
    return try DispatchQueue.main.sync(execute: block)
  }
}

/// Which stored text a configuration change or proposal addresses. `MCPChange.Kind` and
/// `MCPProposal.Kind` each pair with a separate `target: String` field (a section raw value,
/// "profile", or a command name) to say the same thing; `MCPConfigTargets.current(kind:target:)`
/// used to re-derive this pairing with one switch per caller shape. This is the one addressable
/// value both `read`/`write` and the two Kind enums' call sites now go through (R84). It carries
/// no Codable requirement of its own: `MCPChange`/`MCPProposal` still persist their original
/// `kind`/`target` string fields, so the on-disk JSONL format is untouched.
enum MCPConfigTarget: Equatable {
  case glossary
  case systemPrompt(SystemPromptSection)
  case writingStyle
  case command(String)
}

/// The three stores MCP tools read and change, injected so tests use scratch directories.
struct MCPConfigTargets {
  let systemPrompts: SystemPromptsStore
  let writingStyle: WritingStyleStore
  let commands: UserCommandStore

  static var live: MCPConfigTargets {
    MCPConfigTargets(
      systemPrompts: .shared, writingStyle: .shared, commands: .shared)
  }

  /// Current content of a target; nil = does not exist. For `.command`, this is the raw file
  /// (frontmatter + body) — the same representation `write` and restore round-trip through, which
  /// closes a drift where proposals captured a command's `.body` (frontmatter stripped) while the
  /// change log recorded the raw file, so the same edit's previous content differed in form (R84).
  func read(_ target: MCPConfigTarget) -> String? {
    switch target {
    case .glossary:
      return systemPrompts.loadSection(.whisperGlossary)
    case .systemPrompt(let section):
      return systemPrompts.loadSection(section)
    case .writingStyle:
      let text = writingStyle.loadProfile()
      return FileManager.default.fileExists(atPath: writingStyle.profileURL.path) ? text : nil
    case .command(let name):
      return try? String(contentsOf: commands.fileURL(forName: name), encoding: .utf8)
    }
  }

  /// Writes `content` to `target`'s store, in the same representation `read` returns. Used by
  /// restore (undo) and the plain-text apply paths; a command's *initial* save still goes through
  /// `UserCommandStore.save` (it also sets scope/label/description) — restoring a command to a
  /// previously captured raw file is a direct write, since that capture already includes any
  /// frontmatter.
  func write(_ target: MCPConfigTarget, _ content: String) throws {
    switch target {
    case .glossary:
      guard systemPrompts.updateSection(.whisperGlossary, content: content) else {
        throw MCPConfigError(message: "Could not write the glossary.")
      }
    case .systemPrompt(let section):
      guard systemPrompts.updateSection(section, content: content) else {
        throw MCPConfigError(message: "Could not write the \(section.rawValue) section.")
      }
    case .writingStyle:
      writingStyle.saveProfile(content)
      guard writingStyle.loadProfile() == content else {
        throw MCPConfigError(message: "Could not write the writing style profile.")
      }
    case .command(let name):
      AppSupportPaths.ensureDirectoryExists(commands.directoryURL)
      try Data(content.utf8).write(to: commands.fileURL(forName: name), options: .atomic)
      commands.reload()
    }
  }

  static func normalized(_ s: String?) -> String? {
    s?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// The single apply path: level "apply" and an accepted proposal both end here, so both land in
/// the change log. Must run on main (callers wrap with `MCPMain.run`; the methods do it too).
struct MCPConfigApplier {
  let targets: MCPConfigTargets
  let changeLog: MCPChangeLog

  func applyGlossary(merged: String, rationale: String) -> Result<String, Error> {
    MCPMain.run {
      let previous = targets.systemPrompts.loadWhisperGlossary()
      guard targets.systemPrompts.updateSection(.whisperGlossary, content: merged) else {
        return .failure(MCPConfigError(message: "Could not write the glossary."))
      }
      let change = changeLog.record(
        kind: .glossaryAdd, target: SystemPromptSection.whisperGlossary.rawValue,
        previous: previous, new: merged, rationale: rationale, viaProposal: false)
      return .success(change.id)
    }
  }

  func applySystemPrompt(
    section: SystemPromptSection, content: String, rationale: String, viaProposal: Bool
  ) -> Result<String, Error> {
    MCPMain.run {
      let previous = targets.systemPrompts.loadSection(section)
      guard targets.systemPrompts.updateSection(section, content: content) else {
        return .failure(MCPConfigError(message: "Could not write the \(section.rawValue) section."))
      }
      let change = changeLog.record(
        kind: .systemPrompt, target: section.rawValue, previous: previous, new: content,
        rationale: rationale, viaProposal: viaProposal)
      return .success(change.id)
    }
  }

  func applyWritingStyle(content: String, rationale: String, viaProposal: Bool) -> Result<String, Error> {
    MCPMain.run {
      let previous = targets.read(.writingStyle)
      targets.writingStyle.saveProfile(content)
      guard targets.writingStyle.loadProfile() == content else {
        return .failure(MCPConfigError(message: "Could not write the writing style profile."))
      }
      let change = changeLog.record(
        kind: .writingStyle, target: "profile", previous: previous, new: content,
        rationale: rationale, viaProposal: viaProposal)
      return .success(change.id)
    }
  }

  func applySaveCommand(
    name: String, text: String, scope: UserCommandScope, label: String?, description: String?,
    rationale: String, viaProposal: Bool
  ) -> Result<String, Error> {
    MCPMain.run {
      let previous = targets.read(.command(name))
      do {
        try targets.commands.save(
          name: name, text: text, scope: scope, label: label, description: description)
      } catch {
        return .failure(error)
      }
      let written = targets.read(.command(name))
      let change = changeLog.record(
        kind: .saveCommand, target: name, previous: previous, new: written, rationale: rationale,
        viaProposal: viaProposal)
      return .success(change.id)
    }
  }

  func applyDeleteCommand(name: String, rationale: String, viaProposal: Bool) -> Result<String, Error> {
    MCPMain.run {
      guard let previous = targets.read(.command(name)) else {
        return .failure(MCPConfigError(message: "No command named \(name)."))
      }
      do {
        try targets.commands.moveToTrash(targets.commands.fileURL(forName: name))
      } catch {
        return .failure(error)
      }
      let change = changeLog.record(
        kind: .deleteCommand, target: name, previous: previous, new: nil, rationale: rationale,
        viaProposal: viaProposal)
      return .success(change.id)
    }
  }
}
