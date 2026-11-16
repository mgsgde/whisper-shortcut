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

  static let mainWaitTimeout: TimeInterval = 5

  /// A plain `DispatchQueue.main.sync` hangs forever when the main queue is stuck inside a modal
  /// run loop (`NSAlert.runModal`, `NSApp.runModal(for:)`) started from an earlier main-queue
  /// block — the loop doesn't drain queued work until the dialog closes. This bounds the wait so
  /// an MCP request fails fast instead of leaking a worker thread, while still letting a block
  /// that already started running finish and report its real result.
  static func runBounded<T>(timeout: TimeInterval, _ block: @escaping () -> T) -> T? {
    if Thread.isMainThread { return block() }

    let lock = NSLock()
    var state = 0  // 0 = waiting, 1 = started, 2 = abandoned
    var result: T?
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
      lock.lock()
      guard state == 0 else {
        lock.unlock()
        return
      }
      state = 1
      lock.unlock()
      result = block()
      semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + timeout) == .success {
      return result
    }

    lock.lock()
    if state == 0 {
      state = 2
      lock.unlock()
      return nil
    }
    lock.unlock()
    semaphore.wait()
    return result
  }
}

/// The three stores MCP tools read and change, injected so tests use scratch directories.
struct MCPConfigTargets {
  let systemPrompts: SystemPromptsStore
  let writingStyle: WritingStyleStore
  let commands: UserCommandStore
  /// Dictation templates live in UserDefaults; tests swap these for an in-memory list.
  var loadTemplates: () -> [DictationTemplate] = { DictationTemplateStore.load() }
  var saveTemplates: ([DictationTemplate]) -> Void = { DictationTemplateStore.save($0) }
  var loadTemplatePicker: () -> ShortcutDefinition? = { DictationTemplateStore.loadPickerShortcut() }

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
    case .saveTemplate, .deleteTemplate:
      // `target` is the template id; the content is its name + instructions snapshot.
      return UUID(uuidString: target)
        .flatMap { id in loadTemplates().first { $0.id == id } }
        .map { MCPTemplateSnapshot.encode($0, includeShortcut: false) }
    case .settings:
      // `.settings` batches are compared per-item in `MCPChangeLog.undoSettings`, not here.
      return nil
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
      guard targets.systemPrompts.updateSection(.whisperGlossary, content: merged, source: .mcp) else {
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
      guard targets.systemPrompts.updateSection(section, content: content, source: .mcp) else {
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
      targets.writingStyle.markProfileSaved()
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

  /// Creates the template with this id, or replaces its name and instructions. A template's own
  /// shortcut is never touched.
  func applySaveTemplate(
    id: UUID, name: String, text: String, rationale: String, viaProposal: Bool
  ) -> Result<String, Error> {
    MCPMain.run {
      var templates = targets.loadTemplates()
      let existing = templates.firstIndex { $0.id == id }
      let previous = existing.map { MCPTemplateSnapshot.encode(templates[$0], includeShortcut: false) }
      if let existing {
        templates[existing].name = name
        templates[existing].instructions = text
      } else {
        templates.append(DictationTemplate(id: id, name: name, instructions: text))
      }
      targets.saveTemplates(templates)
      guard let written = templates.first(where: { $0.id == id }) else {
        return .failure(MCPConfigError(message: "Could not write the template."))
      }
      let change = changeLog.record(
        kind: .saveTemplate, target: id.uuidString, previous: previous,
        new: MCPTemplateSnapshot.encode(written, includeShortcut: false), rationale: rationale,
        viaProposal: viaProposal)
      return .success(change.id)
    }
  }

  func applyDeleteTemplate(id: UUID, rationale: String, viaProposal: Bool) -> Result<String, Error> {
    MCPMain.run {
      var templates = targets.loadTemplates()
      guard let index = templates.firstIndex(where: { $0.id == id }) else {
        return .failure(MCPConfigError(message: "No template with that id."))
      }
      // The shortcut goes into the snapshot so Undo brings the template back complete.
      let previous = MCPTemplateSnapshot.encode(templates[index], includeShortcut: true)
      templates.remove(at: index)
      targets.saveTemplates(templates)
      let change = changeLog.record(
        kind: .deleteTemplate, target: id.uuidString, previous: previous, new: nil,
        rationale: rationale, viaProposal: viaProposal)
      return .success(change.id)
    }
  }
}

/// A template as the change log stores it: name and instructions as JSON, plus the template's own
/// shortcut only when a delete must be fully undoable.
struct MCPTemplateSnapshot: Codable {
  var name: String
  var instructions: String
  var shortcut: ShortcutDefinition?

  static func encode(_ template: DictationTemplate, includeShortcut: Bool) -> String {
    let snapshot = MCPTemplateSnapshot(
      name: template.name, instructions: template.instructions,
      shortcut: includeShortcut ? template.shortcut : nil)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(snapshot)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  static func decode(_ json: String?) -> MCPTemplateSnapshot? {
    json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(MCPTemplateSnapshot.self, from: $0) }
  }
}
