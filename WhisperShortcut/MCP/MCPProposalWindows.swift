import AppKit
import SwiftUI

/// Review windows for changes AI apps proposed (`MCPProposalStore`).
///
/// Ordinary, non-modal windows, unlike Smart Improvement's panel: a proposal arrives from another
/// app at any moment, and an app-modal panel would freeze every other WhisperShortcut window until
/// it is answered. One window per proposal; opening the same proposal again brings it forward.
final class MCPProposalWindows: NSObject, NSWindowDelegate {
  static let shared = MCPProposalWindows()

  private var windows: [String: NSWindow] = [:]
  private var knownPending = Set<String>()
  private var observer: NSObjectProtocol?

  /// Opens a window as soon as a new proposal arrives: the user just asked their AI app for the
  /// change, so the decision belongs on screen now, not behind a menu.
  func start() {
    guard observer == nil else { return }
    knownPending = Set(MCPProposalStore.shared.pending.map(\.id))
    observer = NotificationCenter.default.addObserver(
      forName: .mcpProposalsDidChange, object: nil, queue: .main
    ) { [weak self] _ in self?.sync() }
  }

  /// Opens every pending proposal (menu item, Settings button).
  func showAll() {
    for proposal in MCPProposalStore.shared.pending { show(proposal) }
  }

  /// `activate` is false when a proposal arrives on its own: the window comes to the front but
  /// does not take the keyboard from the app the user is typing in.
  func show(_ proposal: MCPProposal, activate: Bool = true) {
    if let window = windows[proposal.id] {
      bringForward(window, activate: activate)
      return
    }
    let id = proposal.id
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    if proposal.kind == .problemReport {
      window.title = String(localized: "Problem Report from an AI App")
      window.setContentSize(NSSize(width: 720, height: 640))
      window.contentView = NSHostingView(rootView: ProblemReportReviewView(
        title: proposal.title ?? String(localized: "Problem report"),
        report: proposal.proposedContent ?? "",
        onSend: { [weak self] title, report in self?.sendReport(id, title: title, report: report) },
        onDiscard: { [weak self] in self?.decline(id) }))
    } else if proposal.kind == .settings {
      window.title = "Settings Change from an AI App"
      window.setContentSize(NSSize(width: 560, height: 420))
      window.contentView = NSHostingView(rootView: MCPSettingsProposalReviewView(
        items: proposal.settingsChanges ?? [], rationale: proposal.rationale,
        onAccept: { [weak self] in self?.acceptSettings(id) },
        onCancel: { [weak self] in self?.decline(id) }))
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

  private func reviewView(for proposal: MCPProposal) -> SmartImprovementReviewView {
    let id = proposal.id
    return SmartImprovementReviewView(
      focusDisplayName: Self.title(for: proposal),
      originalText: Self.baseline(for: proposal),
      suggestedText: proposal.proposedContent ?? "",
      rationale: Self.rationale(for: proposal),
      section: proposal.section.flatMap(SystemPromptSection.init(rawValue:)),
      titlePrefix: "Suggested by an AI app",
      cancelTitle: "Decline",
      acceptTitle: proposal.kind == .deleteCommand ? ("Delete Command" as LocalizedStringResource) : "Accept",
      textNoun: Self.noun(for: proposal),
      allowsEditing: proposal.kind != .deleteCommand,
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
    let ids = Set(pending.map(\.id))
    for proposal in pending where !knownPending.contains(proposal.id) { show(proposal, activate: false) }
    // Resolved elsewhere (Settings, another window): close what is left open.
    for (id, window) in windows where !ids.contains(id) { window.close() }
    knownPending = ids
  }

  private func accept(_ id: String, edited: String) {
    let proposal = MCPProposalStore.shared.pending.first { $0.id == id }
    let editedContent = proposal?.kind == .deleteCommand ? nil : edited
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

  /// Marks the report sent and opens it as a prefilled GitHub issue. The browser is the last
  /// stop before anything is public: the user submits it there, or not.
  private func sendReport(_ id: String, title: String, report: String) {
    guard let url = FeedbackLinks.issueURL(title: title, body: report) else {
      DebugLogger.logError("MCP-CONFIG: could not build issue URL for problem report")
      return
    }
    guard NSWorkspace.shared.open(url) else {
      let alert = NSAlert()
      alert.messageText = String(localized: "Couldn't open your browser")
      alert.informativeText = String(localized: "The report is still here. Try again, or copy the text into a new issue on GitHub.")
      alert.runModal()
      return
    }
    _ = MCPProposalStore.shared.accept(id, editedContent: report)
    windows[id]?.close()
  }

  private func acceptSettings(_ id: String) {
    switch MCPProposalStore.shared.accept(id) {
    case .success:
      windows[id]?.close()
    case .failure(let error):
      let alert = NSAlert()
      alert.messageText = "Couldn't apply the change"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }

  private func decline(_ id: String) {
    MCPProposalStore.shared.decline(id)
    windows[id]?.close()
  }

  // MARK: - Names

  /// What the change replaces. A section the user never customized runs on the built-in default,
  /// so that is what the diff compares against, not an empty text.
  static func baseline(for proposal: MCPProposal) -> String {
    if let previous = proposal.previousContent, !previous.isEmpty { return previous }
    guard proposal.kind == .systemPrompt,
      let section = proposal.section.flatMap(SystemPromptSection.init(rawValue:))
    else { return "" }
    return defaultText(for: section)
  }

  /// The built-in text a section runs on until the user customizes it.
  static func defaultText(for section: SystemPromptSection) -> String {
    switch section {
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

  static func noun(for proposal: MCPProposal) -> ReviewNoun {
    switch proposal.kind {
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
    case 1: return "\(items[0].title): \(items[0].fromLabel) → \(items[0].toLabel)"
    case 2: return "\(items[0].title), \(items[1].title)"
    default: return String(localized: "\(items[0].title), \(items[1].title) and \(items.count - 2) more")
    }
  }

  static func title(for change: MCPChange) -> String {
    switch change.kind {
    case .glossaryAdd: return "Glossary"
    case .systemPrompt: return SystemPromptSection(rawValue: change.target).map(displayName) ?? change.target
    case .writingStyle: return String(localized: "Writing style profile")
    case .saveCommand: return change.previousContent == nil ? String(localized: "New command /\(change.target)") : String(localized: "Command /\(change.target)")
    case .deleteCommand: return String(localized: "Deleted command /\(change.target)")
    case .settings: return settingsSummary(change.settingsChanges ?? [])
    }
  }

  static func displayName(_ section: SystemPromptSection) -> String {
    switch section {
    case .dictation: return String(localized: "Dictation instructions")
    case .whisperGlossary: return String(localized: "Glossary")
    case .promptMode: return String(localized: "Dictate Prompt instructions")
    case .chat: return String(localized: "Chat instructions")
    case .readAloudRewrite: return String(localized: "Read Aloud instructions")
    }
  }
}
