import AppKit
import SwiftUI

/// Review windows for changes AI apps proposed (`MCPProposalStore`).
///
/// Ordinary, non-modal review windows. A proposal arrives from another
/// app at any moment, and a modal panel would freeze every other WhisperShortcut window until
/// it is answered. One window per proposal; opening the same proposal again brings it forward.
final class MCPProposalWindows: NSObject, NSWindowDelegate {
  static let shared = MCPProposalWindows()

  private var windows: [String: NSWindow] = [:]
  private var knownPending = Set<String>()
  private var observer: NSObjectProtocol?

  /// True while `start` is watching for proposals. `stop` clears it, so `start` can run again.
  var isStarted: Bool { observer != nil }

  /// Opens a window as soon as a new proposal arrives: the user just asked their AI app for the
  /// change, so the decision belongs on screen now, not behind a menu.
  func start() {
    guard observer == nil else { return }
    knownPending = Set(MCPProposalStore.shared.pending.map(\.id))
    observer = NotificationCenter.default.addObserver(
      forName: .mcpProposalsDidChange, object: nil, queue: .main
    ) { [weak self] _ in self?.sync() }
  }

  /// Undoes `start`: the proposal observer and any review window it opened. Safe when already
  /// stopped. Proposals stay pending; only the windows go away.
  func stop() {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
      self.observer = nil
    }
    knownPending.removeAll()
    let open = Array(windows.values)
    windows.removeAll()
    for window in open {
      window.delegate = nil
      window.close()
    }
  }

  /// Opens every pending proposal (menu item, Settings button).
  func showAll() {
    for proposal in MCPProposalStore.shared.pending { show(proposal) }
  }

  /// `activate` is false when a proposal arrives on its own: the window comes to the front but
  /// does not take the keyboard from the app the user is typing in.
  func show(_ proposal: MCPProposal, activate: Bool = true) {
    if proposal.kind == .problemReport {
      handOffProblemReport(proposal)
      return
    }
    if let window = windows[proposal.id] {
      bringForward(window, activate: activate)
      return
    }
    let id = proposal.id
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    if proposal.kind == .settings {
      window.title = String(localized: "Settings Change from an AI App")
      window.setContentSize(NSSize(width: 560, height: 420))
      window.contentView = NSHostingView(rootView: MCPSettingsProposalReviewView(
        items: proposal.settingsChanges ?? [], rationale: proposal.rationale,
        onAccept: { [weak self] in self?.acceptSettings(id) },
        onCancel: { [weak self] in self?.decline(id) }))
    } else if proposal.isFromWritingStyle {
      // Writing Style found this on its own; "AI app" would point the user at Claude or Codex.
      window.title = String(localized: "Writing Style Suggestion")
      window.contentView = NSHostingView(rootView: reviewView(for: proposal))
    } else {
      window.title = String(localized: "Suggested by an AI app")
      window.contentView = NSHostingView(rootView: reviewView(for: proposal))
    }
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    windows[id] = window
    bringForward(window, activate: activate)
  }

  private func reviewView(for proposal: MCPProposal) -> ProposalReviewView {
    let id = proposal.id
    return ProposalReviewView(
      focusDisplayName: Self.title(for: proposal),
      originalText: Self.baseline(for: proposal),
      suggestedText: proposal.proposedContent ?? "",
      rationale: Self.rationale(for: proposal),
      titlePrefix: proposal.isFromWritingStyle ? "Suggested change" : "Suggested by an AI app",
      cancelTitle: "Decline",
      acceptTitle: Self.acceptTitle(for: proposal),
      textNoun: Self.noun(for: proposal),
      allowsEditing: proposal.kind != .deleteCommand && proposal.kind != .deleteTemplate,
      acceptOnReturn: false,
      onAccept: { [weak self] edited in self?.accept(id, edited: edited) },
      onCancel: { [weak self] in self?.decline(id) })
  }

  private func bringForward(_ window: NSWindow, activate: Bool) {
    if activate {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    } else {
      window.orderFrontRegardless()
    }
  }

  /// Closing the window keeps the proposal pending; only Accept and Decline resolve it.
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      let id = windows.first(where: { $0.value === window })?.key
    else { return }
    windows[id] = nil
  }

  private func sync() {
    let pending = MCPProposalStore.shared.pending
    for proposal in pending where !knownPending.contains(proposal.id) && !proposal.isFromWritingStyle {
      show(proposal, activate: false)
    }
    // A problem report is accepted inside `show`, so re-read before closing windows.
    let stillPending = Set(MCPProposalStore.shared.pending.map(\.id))
    for (id, window) in windows where !stillPending.contains(id) { window.close() }
    knownPending = stillPending
  }

  private func accept(_ id: String, edited: String) {
    let proposal = MCPProposalStore.shared.pending.first { $0.id == id }
    let editedContent = (proposal?.kind == .deleteCommand || proposal?.kind == .deleteTemplate) ? nil : edited
    switch MCPProposalStore.shared.accept(id, editedContent: editedContent) {
    case .success:
      windows[id]?.close()
    case .failure(let error):
      let alert = NSAlert()
      alert.messageText = String(localized: "Couldn't apply the change")
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }

  /// Opens the report window with the proposal prefilled and marks it accepted, so
  /// `get_proposal_status` reports it handed to the user. Nothing is sent until they send the email.
  private func handOffProblemReport(_ proposal: MCPProposal) {
    guard MCPProposalStore.shared.pending.contains(where: { $0.id == proposal.id }) else { return }
    let title = proposal.title ?? ""
    let report = proposal.proposedContent ?? ""
    let message = title.isEmpty ? report : "\(title)\n\n\(report)"
    MainActor.assumeIsolated {
      ProblemReport.open(message: message, startOnGeneral: true)
    }
    switch MCPProposalStore.shared.accept(proposal.id, editedContent: report) {
    case .success:
      DebugLogger.log("MCP-CONFIG: problem report handed to the user id=\(proposal.id)")
    case .failure(let error):
      DebugLogger.logError(
        "MCP-CONFIG: could not mark problem report accepted: \(error.logDescription)")
    }
  }

  private func acceptSettings(_ id: String) {
    switch MCPProposalStore.shared.accept(id) {
    case .success:
      windows[id]?.close()
    case .failure(let error):
      let alert = NSAlert()
      alert.messageText = String(localized: "Couldn't apply the change")
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }

  private func decline(_ id: String) {
    MCPProposalStore.shared.decline(id)
    windows[id]?.close()
  }

  // MARK: - Names

  /// What the change replaces. When the stored text is empty, the diff uses the section's shipped
  /// default: empty additional instructions for Dictation and Dictate Prompt, the full prompt for
  /// the other sections.
  static func baseline(for proposal: MCPProposal) -> String {
    if let previous = proposal.previousContent, !previous.isEmpty { return previous }
    guard proposal.kind == .systemPrompt,
      let section = proposal.section.flatMap(SystemPromptSection.init(rawValue:))
    else { return "" }
    return defaultText(for: section)
  }

  /// The text a section holds until the user customizes it. Dictation and Dictate Prompt hold only
  /// additional instructions (empty until the user adds some); their fixed cores live in code.
  static func defaultText(for section: SystemPromptSection) -> String {
    switch section {
    case .dictationAdditions, .promptModeAdditions: return ""
    case .dictation: return AppConstants.defaultTranscriptionSystemPrompt
    case .whisperGlossary: return AppConstants.defaultWhisperGlossary
    case .promptMode: return AppConstants.defaultPromptModeSystemPrompt
    case .chat: return AppConstants.defaultChatSystemPrompt
    case .readAloudRewrite: return AppConstants.defaultReadAloudRewritePrompt
    }
  }

  /// A saved command also sets where it appears and its button label; Accept applies those too,
  /// so they belong next to the reason.
  static func rationale(for proposal: MCPProposal) -> String {
    guard proposal.kind == .saveCommand else { return proposal.rationale }
    var details: [String] = []
    if let scope = proposal.commandScope, !scope.isEmpty { details.append(String(localized: "Appears in: \(scope)")) }
    if let label = proposal.commandLabel, !label.isEmpty { details.append(String(localized: "Button: \(label)")) }
    if let description = proposal.commandDescription, !description.isEmpty {
      details.append(String(localized: "Description: \(description)"))
    }
    guard !details.isEmpty else { return proposal.rationale }
    return proposal.rationale + "\n\n" + details.joined(separator: "\n")
  }

  static func acceptTitle(for proposal: MCPProposal) -> LocalizedStringResource {
    switch proposal.kind {
    case .deleteCommand: return "Delete Command"
    case .deleteTemplate: return "Delete Template"
    default: return "Accept"
    }
  }

  static func noun(for proposal: MCPProposal) -> ReviewNoun {
    switch proposal.kind {
    case .saveTemplate, .deleteTemplate: return .instructions
    case .systemPrompt: return .instructions
    case .writingStyle: return .profile
    case .saveCommand, .deleteCommand: return .command
    case .problemReport: return .report
    case .settings: return .settings
    }
  }

  static func title(for proposal: MCPProposal) -> String {
    switch proposal.kind {
    case .systemPrompt:
      return proposal.section.flatMap(SystemPromptSection.init(rawValue:)).map(displayName) ?? String(localized: "Instructions")
    case .writingStyle: return String(localized: "Writing style profile")
    case .saveCommand:
      return proposal.previousContent == nil
        ? String(localized: "New command /\(proposal.commandName ?? "")") : String(localized: "Command /\(proposal.commandName ?? "")")
    case .deleteCommand: return String(localized: "Delete command /\(proposal.commandName ?? "")")
    case .saveTemplate:
      let name = proposal.templateName ?? ""
      return proposal.previousContent == nil
        ? String(localized: "New template \u{201C}\(name)\u{201D}") : String(localized: "Template \u{201C}\(name)\u{201D}")
    case .deleteTemplate:
      let name = proposal.templateName ?? ""
      return String(localized: "Delete template \u{201C}\(name)\u{201D}")
    case .problemReport: let reportTitle = proposal.title ?? String(localized: "untitled")
      return String(localized: "Problem report: \(reportTitle)")
    case .settings: return settingsSummary(proposal.settingsChanges ?? [])
    }
  }

  /// One line for a settings batch: the change itself when there is one ("Dictation model:
  /// GPT Transcribe → Gemini Flash"), else the first two titles and how many more.
  static func settingsSummary(_ items: [MCPSettingsChangeItem]) -> String {
    switch items.count {
    case 0: return String(localized: "Settings")
    case 1:
      return "\(MCPSettingsCatalog.reviewTitle(items[0].title)): \(MCPSettingsCatalog.reviewLabel(items[0].fromLabel)) → \(MCPSettingsCatalog.reviewLabel(items[0].toLabel))"
    case 2:
      return "\(MCPSettingsCatalog.reviewTitle(items[0].title)), \(MCPSettingsCatalog.reviewTitle(items[1].title))"
    default:
      let first = MCPSettingsCatalog.reviewTitle(items[0].title)
      let second = MCPSettingsCatalog.reviewTitle(items[1].title)
      return String(localized: "\(first), \(second) and \(items.count - 2) more")
    }
  }

  static func title(for change: MCPChange) -> String {
    switch change.kind {
    case .glossaryAdd: return String(localized: "Glossary")
    case .systemPrompt: return SystemPromptSection(rawValue: change.target).map(displayName) ?? change.target
    case .writingStyle: return String(localized: "Writing style profile")
    case .saveCommand: return change.previousContent == nil ? String(localized: "New command /\(change.target)") : String(localized: "Command /\(change.target)")
    case .deleteCommand: return String(localized: "Deleted command /\(change.target)")
    case .saveTemplate:
      let name = MCPTemplateSnapshot.decode(change.newContent ?? change.previousContent)?.name ?? ""
      return change.previousContent == nil
        ? String(localized: "New template \u{201C}\(name)\u{201D}") : String(localized: "Template \u{201C}\(name)\u{201D}")
    case .deleteTemplate:
      let name = MCPTemplateSnapshot.decode(change.previousContent)?.name ?? ""
      return String(localized: "Deleted template \u{201C}\(name)\u{201D}")
    case .settings: return settingsSummary(change.settingsChanges ?? [])
    }
  }

  static func displayName(_ section: SystemPromptSection) -> String {
    switch section {
    case .dictationAdditions: return "Dictation additions"
    case .promptModeAdditions: return "Dictate Prompt additions"
    case .dictation: return String(localized: "Dictation instructions")
    case .whisperGlossary: return String(localized: "Glossary")
    case .promptMode: return String(localized: "Dictate Prompt instructions")
    case .chat: return String(localized: "Chat instructions")
    case .readAloudRewrite: return String(localized: "Read Aloud instructions")
    }
  }
}
