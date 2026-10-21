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
    let view = SmartImprovementReviewView(
      focusDisplayName: Self.title(for: proposal),
      originalText: proposal.previousContent ?? "",
      suggestedText: proposal.proposedContent ?? "",
      rationale: proposal.rationale,
      section: proposal.section.flatMap(SystemPromptSection.init(rawValue:)),
      titlePrefix: "Suggested by an AI app",
      cancelTitle: "Decline",
      acceptTitle: proposal.kind == .deleteCommand ? "Delete Command" : "Accept",
      textNoun: Self.noun(for: proposal),
      allowsEditing: proposal.kind != .deleteCommand,
      acceptOnReturn: false,
      onAccept: { [weak self] edited in self?.accept(id, edited: edited) },
      onCancel: { [weak self] in self?.decline(id) })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = "Suggested by an AI app"
    window.contentView = NSHostingView(rootView: view)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    windows[id] = window
    bringForward(window, activate: activate)
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

  static func noun(for proposal: MCPProposal) -> String {
    switch proposal.kind {
    case .systemPrompt: return "instructions"
    case .writingStyle: return "profile"
    case .saveCommand, .deleteCommand: return "command"
    }
  }

  static func title(for proposal: MCPProposal) -> String {
    switch proposal.kind {
    case .systemPrompt:
      return proposal.section.flatMap(SystemPromptSection.init(rawValue:)).map(displayName) ?? "Instructions"
    case .writingStyle: return "Writing style profile"
    case .saveCommand:
      return proposal.previousContent == nil
        ? "New command /\(proposal.commandName ?? "")" : "Command /\(proposal.commandName ?? "")"
    case .deleteCommand: return "Delete command /\(proposal.commandName ?? "")"
    }
  }

  static func title(for change: MCPChange) -> String {
    switch change.kind {
    case .glossaryAdd: return "Glossary"
    case .systemPrompt: return SystemPromptSection(rawValue: change.target).map(displayName) ?? change.target
    case .writingStyle: return "Writing style profile"
    case .saveCommand: return change.previousContent == nil ? "New command /\(change.target)" : "Command /\(change.target)"
    case .deleteCommand: return "Deleted command /\(change.target)"
    }
  }

  static func displayName(_ section: SystemPromptSection) -> String {
    switch section {
    case .dictation: return "Dictation instructions"
    case .whisperGlossary: return "Glossary"
    case .promptMode: return "Dictate Prompt instructions"
    case .chat: return "Chat instructions"
    case .readAloudRewrite: return "Read Aloud instructions"
    }
  }
}
