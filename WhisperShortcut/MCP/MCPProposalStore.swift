import Combine
import Foundation

extension Notification.Name {
  /// Posted on main whenever a proposal is created, accepted or declined.
  static let mcpProposalsDidChange = Notification.Name("mcpProposalsDidChange")
}

/// A change an AI app asked for that waits for the user's decision.
struct MCPProposal: Codable, Identifiable {
  enum Kind: String, Codable { case systemPrompt, writingStyle, saveCommand, deleteCommand }
  enum Status: String, Codable { case pending, accepted, declined }

  let id: String
  let createdAt: Date
  let kind: Kind
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
}

/// Pending AI-app proposals in `UserContext/mcp-proposals.jsonl`, so a quit does not lose them.
final class MCPProposalStore: ObservableObject {
  static let shared = MCPProposalStore(
    directory: AppSupportPaths.userContextURL(),
    applier: MCPConfigApplier(targets: .live, changeLog: .shared))

  static let fileName = "mcp-proposals.jsonl"
  /// Resolved proposals kept so `get_proposal_status` can still answer.
  static let maxResolved = 100

  /// Mutated on main.
  @Published private(set) var pending: [MCPProposal] = []

  private var all: [MCPProposal] = []
  private let fileURL: URL
  var applier: MCPConfigApplier?

  init(directory: URL, applier: MCPConfigApplier? = nil) {
    self.fileURL = directory.appendingPathComponent(Self.fileName)
    self.applier = applier
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
      DebugLogger.logError("MCP-CONFIG: could not write proposals: \(error.localizedDescription)")
    }
    NotificationCenter.default.post(name: .mcpProposalsDidChange, object: nil)
  }

  /// Stores a new pending proposal. Runs on main.
  func create(
    kind: MCPProposal.Kind, section: String? = nil, commandName: String? = nil,
    commandScope: String? = nil, commandLabel: String? = nil, commandDescription: String? = nil,
    previousContent: String?, proposedContent: String?, rationale: String
  ) -> MCPProposal {
    MCPMain.run {
      let proposal = MCPProposal(
        id: UUID().uuidString, createdAt: Date(), kind: kind, section: section,
        commandName: commandName, commandScope: commandScope, commandLabel: commandLabel,
        commandDescription: commandDescription, previousContent: previousContent,
        proposedContent: proposedContent, rationale: rationale, status: .pending, edited: false)
      all.append(proposal)
      commit()
      return proposal
    }
  }

  /// Applies the proposal (optionally with the user's edited text) through the same path as access
  /// level "apply" and returns the change id. A failed apply leaves the proposal pending.
  func accept(_ id: String, editedContent: String? = nil) -> Result<String, Error> {
    MCPMain.run {
      guard let index = all.firstIndex(where: { $0.id == id && $0.status == .pending }) else {
        return .failure(MCPConfigError(message: "No pending proposal with that id."))
      }
      guard let applier else { return .failure(MCPConfigError(message: "Proposals are not available.")) }
      var proposal = all[index]
      if proposal.kind != .deleteCommand, let editedContent, editedContent != proposal.proposedContent {
        proposal.proposedContent = editedContent
        proposal.edited = true
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
