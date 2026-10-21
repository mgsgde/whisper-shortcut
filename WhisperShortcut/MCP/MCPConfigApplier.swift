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

/// The three stores MCP tools read and change, injected so tests use scratch directories.
struct MCPConfigTargets {
  let systemPrompts: SystemPromptsStore
  let writingStyle: WritingStyleStore
  let commands: UserCommandStore

  static var live: MCPConfigTargets {
    MCPConfigTargets(
      systemPrompts: .shared, writingStyle: .shared, commands: .shared)
  }

  /// Current content of a change target; nil = does not exist.
  func current(kind: MCPChange.Kind, target: String) -> String? {
    switch kind {
    case .glossaryAdd:
      return systemPrompts.loadSection(.whisperGlossary)
    case .systemPrompt:
      return SystemPromptSection(rawValue: target).flatMap { systemPrompts.loadSection($0) }
    case .writingStyle:
      let text = writingStyle.loadProfile()
      return FileManager.default.fileExists(atPath: writingStyle.profileURL.path) ? text : nil
    case .saveCommand, .deleteCommand:
      return try? String(contentsOf: commands.fileURL(forName: target), encoding: .utf8)
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
      let previous = targets.current(kind: .writingStyle, target: "profile")
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
      let previous = targets.current(kind: .saveCommand, target: name)
      do {
        try targets.commands.save(
          name: name, text: text, scope: scope, label: label, description: description)
      } catch {
        return .failure(error)
      }
      let written = targets.current(kind: .saveCommand, target: name)
      let change = changeLog.record(
        kind: .saveCommand, target: name, previous: previous, new: written, rationale: rationale,
        viaProposal: viaProposal)
      return .success(change.id)
    }
  }

  func applyDeleteCommand(name: String, rationale: String, viaProposal: Bool) -> Result<String, Error> {
    MCPMain.run {
      guard let previous = targets.current(kind: .deleteCommand, target: name) else {
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
