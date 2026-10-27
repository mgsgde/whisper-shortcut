import Combine
import Foundation

extension Notification.Name {
  /// Posted on main whenever a proposal is created, accepted or declined.
  static let mcpProposalsDidChange = Notification.Name("mcpProposalsDidChange")
}

/// A change an AI app asked for that waits for the user's decision.
struct MCPProposal: Codable, Identifiable {
  enum Kind: String, Codable { case systemPrompt, writingStyle, saveCommand, deleteCommand, problemReport, settings }
  enum Status: String, Codable { case pending, accepted, declined }

  let id: String
  let createdAt: Date
  let kind: Kind
  /// Short summary for a `.problemReport`. Optional so older JSONL lines still decode.
  var title: String?
  /// `SystemPromptSection` raw value for `.systemPrompt`.
  var section: String?
  var commandName: String?
  /// "meeting" | "chat" | "both"
  var commandScope: String?
  var commandLabel: String?
  var commandDescription: String?
  /// What is there when the proposal was made (for the diff). nil = did not exist.
  var previousContent: String?
  /// The proposed text (command body for `.saveCommand`). nil for `.deleteCommand`.
  var proposedContent: String?
  let rationale: String
  var status: Status
  /// True when the user changed the text before accepting.
  var edited: Bool
  /// The batch, for `.settings` only. Optional so older JSONL lines without this field still decode.
  var settingsChanges: [MCPSettingsChangeItem]? = nil
}

/// Pending AI-app proposals in `UserContext/mcp-proposals.jsonl`, so a quit does not lose them.
final class MCPProposalStore: ObservableObject {
  static let shared = MCPProposalStore(
    directory: AppSupportPaths.userContextURL(),
    applier: MCPConfigApplier(targets: .live, changeLog: .shared),
    settingsCatalog: MCPSettingsCatalog.build(.live))

  static let fileName = "mcp-proposals.jsonl"
  /// Resolved proposals kept so `get_proposal_status` can still answer.
  static let maxResolved = 100
  /// Most proposals that may wait for the user at once.
  static let maxPending = 20

  /// Mutated on main.
  @Published private(set) var pending: [MCPProposal] = []

  private var all: [MCPProposal] = []
  private let fileURL: URL
  var applier: MCPConfigApplier?
  /// Used only to accept/apply a `.settings` proposal. Empty in tests that don't need it.
  var settingsCatalog: [MCPSetting]

  init(directory: URL, applier: MCPConfigApplier? = nil, settingsCatalog: [MCPSetting] = []) {
    self.fileURL = directory.appendingPathComponent(Self.fileName)
    self.applier = applier
    self.settingsCatalog = settingsCatalog
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
      all = text.components(separatedBy: .newlines).compactMap { line in
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
        return try? d.decode(MCPProposal.self, from: data)
      }
    }
    pending = all.filter { $0.status == .pending }
  }

  private func commit() {
    let resolved = all.filter { $0.status != .pending }
    if resolved.count > Self.maxResolved {
      let drop = Set(resolved.prefix(resolved.count - Self.maxResolved).map(\.id))
      all.removeAll { drop.contains($0.id) }
    }
    pending = all.filter { $0.status == .pending }
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    let lines = all.compactMap { p in (try? e.encode(p)).flatMap { String(data: $0, encoding: .utf8) } }
    do {
      AppSupportPaths.ensureDirectoryExists(fileURL.deletingLastPathComponent())
      try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    } catch {
      DebugLogger.logError("MCP-CONFIG: could not write proposals: \(error.logDescription)")
    }
    NotificationCenter.default.post(name: .mcpProposalsDidChange, object: nil)
  }

  /// Stores a new pending proposal. Runs on main.
  func create(
    kind: MCPProposal.Kind, title: String? = nil, section: String? = nil, commandName: String? = nil,
    commandScope: String? = nil, commandLabel: String? = nil, commandDescription: String? = nil,
    previousContent: String? = nil, proposedContent: String? = nil, rationale: String,
    settingsChanges: [MCPSettingsChangeItem]? = nil
  ) throws -> MCPProposal {
    try MCPMain.run {
      // A newer proposal for the same target replaces the older one.
      let sameTarget = all.indices.filter { i in
        let q = all[i]
        guard q.status == .pending, q.kind == kind || Self.sameTargetGroup(q.kind, kind) else { return false }
        switch kind {
        case .systemPrompt: return q.section == section
        case .writingStyle: return true
        case .saveCommand, .deleteCommand: return q.commandName == commandName
        case .problemReport: return false
        // One pending settings proposal at a time: a later one supersedes it wholesale.
        case .settings: return true
        }
      }
      if sameTarget.isEmpty, pending.count >= Self.maxPending {
        throw MCPConfigError(
          message: "Too many changes are waiting for approval in WhisperShortcut. Ask the user to review them first.")
      }
      for i in sameTarget { all[i].status = .declined }
      let proposal = MCPProposal(
        id: UUID().uuidString, createdAt: Date(), kind: kind, title: title, section: section,
        commandName: commandName, commandScope: commandScope, commandLabel: commandLabel,
        commandDescription: commandDescription, previousContent: previousContent,
        proposedContent: proposedContent, rationale: rationale, status: .pending, edited: false,
        settingsChanges: settingsChanges)
      all.append(proposal)
      commit()
      return proposal
    }
  }

  /// save and delete of one command name target the same file.
  private static func sameTargetGroup(_ a: MCPProposal.Kind, _ b: MCPProposal.Kind) -> Bool {
    (a == .saveCommand || a == .deleteCommand) && (b == .saveCommand || b == .deleteCommand)
  }

  /// What the target holds now, in the form `previousContent` was captured at create time.
  private func currentForCompare(_ proposal: MCPProposal, applier: MCPConfigApplier) -> String? {
    switch proposal.kind {
    case .systemPrompt:
      return proposal.section.flatMap(SystemPromptSection.init(rawValue:)).flatMap {
        applier.targets.systemPrompts.loadSection($0)
      }
    case .writingStyle:
      return applier.targets.current(kind: .writingStyle, target: "profile")
    case .saveCommand, .deleteCommand:
      applier.targets.commands.reload()
      return applier.targets.commands.commands.first { $0.name == proposal.commandName }?.body
    case .problemReport, .settings:
      // `.settings` is compared per-item in `accept()`, not here.
      return nil
    }
  }

  /// Applies the proposal (optionally with the user's edited text) through the same path as access
  /// level "apply" and returns the change id. A problem report is only marked accepted: nothing is
  /// applied and no change is logged. A failed apply leaves the proposal pending.
  func accept(_ id: String, editedContent: String? = nil) -> Result<String, Error> {
    MCPMain.run {
      guard let index = all.firstIndex(where: { $0.id == id && $0.status == .pending }) else {
        return .failure(MCPConfigError(message: "No pending proposal with that id."))
      }
      var proposal = all[index]
      // No editing for `.settings`: the proposal window for settings has no text field to edit.
      if proposal.kind == .settings {
        guard let items = proposal.settingsChanges else {
          return .failure(MCPConfigError(message: "This proposal has no settings."))
        }
        guard let applier else { return .failure(MCPConfigError(message: "Proposals are not available.")) }
        let result = applier.applySettingsBatch(
          catalog: settingsCatalog, items: items, rationale: proposal.rationale, viaProposal: true)
        if case .success = result {
          proposal.status = .accepted
          all[index] = proposal
          commit()
          DebugLogger.log("MCP-CONFIG: proposal settings accepted count=\(items.count)")
        }
        return result
      }
      if proposal.kind != .deleteCommand, let editedContent, editedContent != proposal.proposedContent {
        proposal.proposedContent = editedContent
        proposal.edited = true
      }
      if proposal.kind == .problemReport {
        proposal.status = .accepted
        all[index] = proposal
        commit()
        let content = proposal.proposedContent ?? ""
        DebugLogger.log("MCP-CONFIG: proposal \(proposal.kind.rawValue) accepted edited=\(proposal.edited) len=\(content.count)")
        return .success(proposal.id)
      }
      guard let applier else { return .failure(MCPConfigError(message: "Proposals are not available.")) }
      let now = MCPConfigTargets.normalized(currentForCompare(proposal, applier: applier)) ?? ""
      if now != (MCPConfigTargets.normalized(proposal.previousContent) ?? "") {
        DebugLogger.log("MCP-CONFIG: proposal \(proposal.kind.rawValue) accept rejected (changed since)")
        return .failure(MCPConfigError(
          message: "This changed since the AI app suggested it. Decline it and ask the AI app again."))
      }
      let content = proposal.proposedContent ?? ""
      let result: Result<String, Error>
      switch proposal.kind {
      case .systemPrompt:
        guard let section = proposal.section.flatMap(SystemPromptSection.init(rawValue:)) else {
          return .failure(MCPConfigError(message: "Unknown section."))
        }
        result = applier.applySystemPrompt(
          section: section, content: content, rationale: proposal.rationale, viaProposal: true)
      case .writingStyle:
        result = applier.applyWritingStyle(content: content, rationale: proposal.rationale, viaProposal: true)
      case .saveCommand:
        result = applier.applySaveCommand(
          name: proposal.commandName ?? "", text: content,
          scope: proposal.commandScope.flatMap(UserCommandScope.init(rawValue:)) ?? .both,
          label: proposal.commandLabel, description: proposal.commandDescription,
          rationale: proposal.rationale, viaProposal: true)
      case .deleteCommand:
        result = applier.applyDeleteCommand(
          name: proposal.commandName ?? "", rationale: proposal.rationale, viaProposal: true)
      case .problemReport, .settings:
        // problemReport is accepted above, before any applier call; settings returns early at the
        // top of this function. Both arms are unreachable here and only keep the switch exhaustive.
        result = .success(proposal.id)
      }
      if case .success = result {
        proposal.status = .accepted
        all[index] = proposal
        commit()
        DebugLogger.log("MCP-CONFIG: proposal \(proposal.kind.rawValue) accepted edited=\(proposal.edited) len=\(content.count)")
      }
      return result
    }
  }

  func decline(_ id: String) {
    MCPMain.run {
      guard let index = all.firstIndex(where: { $0.id == id && $0.status == .pending }) else { return }
      all[index].status = .declined
      commit()
      DebugLogger.log("MCP-CONFIG: proposal \(all[index].kind.rawValue) declined")
    }
  }

  func status(of id: String) -> MCPProposal? {
    MCPMain.run { all.first { $0.id == id } }
  }
}
