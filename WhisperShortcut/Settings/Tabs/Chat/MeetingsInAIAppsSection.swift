import AppKit
import SwiftUI

/// Settings UI for the local MCP server (`MCPServer`): lets Claude Code, Claude Desktop and other
/// MCP clients on this Mac read meeting transcripts, including the one recording right now, and,
/// if the user allows it, improve the setup (glossary, instructions, writing style, commands).
///
/// Off by default. When on, it offers a "Connect Claude Code" button (copy + open Terminal, then a
/// live "connected" check from `MCPClientRegistry`) and a ready-to-paste Claude Desktop config,
/// both carrying the access key. The key in the setup
/// follows the access level: the read key while AI apps may only read, the write key otherwise.
struct MeetingsInAIAppsSection: View {
  @ObservedObject private var server = MCPServer.shared
  @ObservedObject private var proposals = MCPProposalStore.shared
  @ObservedObject private var changeLog = MCPChangeLog.shared
  @ObservedObject private var clients = MCPClientRegistry.shared

  @AppStorage(UserDefaultsKeys.mcpConfigAccessLevel) private var accessLevelRaw = MCPConfigAccessLevel.read.rawValue
  @AppStorage(UserDefaultsKeys.mcpShareRecentInteractions) private var shareRecentInteractions = false
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var contextLoggingEnabled = false

  /// Changes listed under "Changed by AI apps"; the full record stays in `mcp-changes.jsonl`.
  private static let visibleChanges = 5

  /// Pinned so a new `mcp-remote` release can't change what users paste. Bump deliberately.
  private static let mcpRemotePackage = "mcp-remote@0.14.3"
  private static let serverName = "whisper-shortcut"

  @State private var copiedItem: String?
  @State private var showRegenerateConfirm = false
  @State private var undoMessage: String?
  @State private var showAllChanges = false
  /// Set when "Connect Claude Code" was clicked; drives the steps and the "Waiting…" state until
  /// Claude Code's next `initialize` arrives.
  @State private var connectStartedAt: Date?
  @State private var showClaudeCodeCommand = false

  /// `clientInfo.name` prefixes the two tested clients send in `initialize`. Claude Desktop's
  /// name passes through mcp-remote unchanged.
  private static let claudeCodeClient = "claude-code"
  private static let claudeDesktopClient = "claude-ai"

  private var accessLevel: MCPConfigAccessLevel {
    MCPConfigAccessLevel(rawValue: accessLevelRaw) ?? .read
  }

  /// The key the setup cards carry.
  private var setupToken: String {
    // nil only on a transient Keychain failure; show empty rather than crash — the UI already
    // treats an empty token as "not ready yet".
    (accessLevel == .read ? server.token() : server.writeToken()) ?? ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Claude & Other AI Apps",
        systemImage: "point.3.connected.trianglepath.dotted",
        subtitle: "Let Claude and other MCP apps on this Mac read your meetings, including the one recording right now. If you allow it, they can also improve your setup from what they already know about you: names for the glossary, how your messages should sound, your commands."
      )

      Toggle("Allow AI apps on this Mac to connect", isOn: Binding(
        get: { server.isEnabled },
        set: { server.isEnabled = $0 }
      ))
      .toggleStyle(.switch)

      statusRow

      if server.isEnabled {
        accessPicker

        if accessLevel != .read {
          pendingProposals
          recentChanges
        }

        claudeCodeCard

        setupCard(
          id: "claude-desktop",
          title: "Claude Desktop",
          clientPrefix: Self.claudeDesktopClient,
          instruction: "In Claude, open Settings → Developer → Edit Config, paste this into claude_desktop_config.json (merge it with any servers already there), then quit and reopen Claude. Needs Node.js.",
          code: claudeDesktopConfig
        )

        Text(privacyNote)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Button("New access key…") { showRegenerateConfirm = true }
          Text("Apps you already set up stop working until you paste the new setup.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .confirmationDialog(
          "Create a new access key?",
          isPresented: $showRegenerateConfirm
        ) {
          Button("Create New Key", role: .destructive) {
            server.regenerateToken()
            server.regenerateWriteToken()
            // Every app connected so far holds the old key, so none of them counts as connected.
            clients.forgetAll()
            connectStartedAt = nil
          }
        } message: {
          Text("Claude and other apps set up with the current key lose access until you copy the new setup into them.")
        }
      }
    }
  }

  // MARK: - Access

  private var accessPicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("AI apps may", selection: $accessLevelRaw) {
        Text("Only read").tag(MCPConfigAccessLevel.read.rawValue)
        Text("Suggest changes for me to approve").tag(MCPConfigAccessLevel.propose.rawValue)
        Text("Make changes directly").tag(MCPConfigAccessLevel.apply.rawValue)
      }
      .pickerStyle(.radioGroup)

      Text(accessCaption)
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if accessLevel != .read {
        Toggle("Let AI apps read my recent dictations", isOn: $shareRecentInteractions)
          .disabled(!contextLoggingEnabled)
          .padding(.top, 4)
        Text(contextLoggingEnabled
          ? "So you can ask \"why did it get that wrong?\" and the AI app looks at what you dictated in the last 7 days."
          : "Needs \"Save usage data\" in Smart Improvement. Then you can ask \"why did it get that wrong?\" and the AI app looks at your recent dictations.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var accessCaption: String {
    switch accessLevel {
    case .read:
      return "AI apps can read meetings and your setup, never change anything."
    case .propose:
      return "Each change opens here for you to accept, edit or decline. New glossary terms are added right away, since they never replace anything. Connect your AI app again below so it gets the new access."
    case .apply:
      return "Changes apply at once and can be undone below. Dictation and Chat instructions still wait for your approval: a meeting or email an AI app reads could contain text meant to change them. Connect your AI app again below so it gets the new access."
    }
  }

  private var privacyNote: String {
    let what = accessLevel == .read
      ? "AI apps can read transcripts, notes, summaries and your setup, never change or delete them."
      : "AI apps can read your meetings and setup and change the glossary, instructions, writing style and commands. API keys are never shared."
    return what + " Only apps set up with your access key get in, and nothing is reachable from other devices. What you read in an AI app is sent to that app's provider."
  }

  // MARK: - Proposals and changes

  @ViewBuilder
  private var pendingProposals: some View {
    if !proposals.pending.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Waiting for your approval")
            .font(.callout)
            .fontWeight(.semibold)
          Spacer()
          if proposals.pending.count > 1 {
            Button("Review All") { MCPProposalWindows.shared.showAll() }
              .controlSize(.small)
          }
        }
        ForEach(proposals.pending) { proposal in
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(MCPProposalWindows.title(for: proposal))
                .font(.callout)
              Text(proposal.rationale)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            }
            Spacer()
            Button("Review…") { MCPProposalWindows.shared.show(proposal) }
              .controlSize(.small)
          }
        }
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
  }

  @ViewBuilder
  private var recentChanges: some View {
    let all = changeLog.changes
    if !all.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Changed by AI apps")
          .font(.callout)
          .fontWeight(.semibold)
        ForEach(showAllChanges ? all : Array(all.prefix(Self.visibleChanges))) { change in
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(MCPProposalWindows.title(for: change))
                  .font(.callout)
                  .strikethrough(change.undoneAt != nil)
                Text(change.appliedAt.formatted(.relative(presentation: .named)))
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              Text(change.rationale)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            }
            Spacer()
            if change.undoneAt != nil {
              Text("Undone")
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
              Button("Undo") { undo(change) }
                .controlSize(.small)
            }
          }
        }
        if all.count > Self.visibleChanges {
          Button(showAllChanges ? "Show fewer" : "Show all \(all.count)") { showAllChanges.toggle() }
            .buttonStyle(.link)
            .font(.caption)
        }
        if let undoMessage {
          Text(undoMessage)
            .font(.caption)
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
  }

  private func undo(_ change: MCPChange) {
    switch changeLog.undo(change.id) {
    case .undone:
      undoMessage = nil
    case .conflict:
      undoMessage = "\(MCPProposalWindows.title(for: change)) was changed again after this, so it was left as it is. Edit it in Settings instead."
    case .notFound:
      undoMessage = "This change is no longer on record."
    case .failed(let message):
      undoMessage = "Couldn't undo: \(message)"
    }
  }

  // MARK: - Status

  @ViewBuilder
  private var statusRow: some View {
    HStack(spacing: 8) {
      switch server.status {
      case .running:
        Image(systemName: "circle.fill").foregroundColor(.green).font(.system(size: 8))
        Text("Running at \(server.endpointURL)")
          .font(.callout)
          .textSelection(.enabled)
      case .failed(let message):
        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        Text("Couldn't start: \(message)")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      case .stopped:
        Image(systemName: "circle").foregroundColor(.secondary).font(.system(size: 8))
        Text(server.isEnabled ? "Starting…" : "Off")
          .font(.callout)
          .foregroundColor(.secondary)
      }
    }
  }

  // MARK: - Claude Code

  /// The app is sandboxed, so it cannot run `claude mcp add` itself (that writes ~/.claude.json).
  /// The button does the rest: copies the command, opens Terminal, and then watches for Claude
  /// Code's `initialize` so the user sees the setup worked, or that it still holds the read key.
  private var claudeCodeCard: some View {
    let connection = clients.client(matching: Self.claudeCodeClient)
    let waiting = connectStartedAt.map { started in
      connection.map { $0.lastConnected < started } ?? true
    } ?? false

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Claude Code")
          .font(.callout)
          .fontWeight(.semibold)
        Spacer()
        connectionBadge(connection, waiting: waiting)
      }

      HStack(spacing: 10) {
        Button {
          connectClaudeCode()
        } label: {
          Label(connection == nil ? "Connect Claude Code" : "Connect Again", systemImage: "terminal")
        }
        .buttonStyle(.borderedProminent)
        .disabled(setupToken.isEmpty)

        Button(showClaudeCodeCommand ? "Hide command" : "Show command") {
          showClaudeCodeCommand.toggle()
        }
        .buttonStyle(.link)
        .font(.caption)
      }

      if setupToken.isEmpty {
        Text("The access key couldn't be read from the Keychain. Unlock your Mac's login keychain, then reopen Settings.")
          .font(.caption)
          .foregroundColor(.orange)
          .fixedSize(horizontal: false, vertical: true)
      } else if waiting {
        connectSteps
      } else if let connection, needsWriteKey(connection) {
        Text("Claude Code is connected with the read-only key, so it can't suggest or make changes. Click Connect Again, then start a new Claude Code session.")
          .font(.caption)
          .foregroundColor(.orange)
          .fixedSize(horizontal: false, vertical: true)
      } else if connection == nil {
        Text("Copies a setup command and opens Terminal. You paste it once, and every new Claude Code session can use WhisperShortcut.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if showClaudeCodeCommand {
        HStack(alignment: .top) {
          codeBlock(claudeCodeCommand)
          Button {
            copy(claudeCodeCommand, id: "claude-code")
          } label: {
            Image(systemName: copiedItem == "claude-code" ? "checkmark" : "doc.on.doc")
          }
          .controlSize(.small)
          .help("Copy command")
        }
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private var connectSteps: some View {
    VStack(alignment: .leading, spacing: 6) {
      connectStep(1, "In Terminal, press ⌘V, then Return.")
      connectStep(2, "Start a new Claude Code session. In one that's already open, run /mcp and reconnect whisper-shortcut.")
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Waiting for Claude Code to connect…")
          .font(.caption)
          .foregroundColor(.secondary)
        Spacer()
        Button("Cancel") { connectStartedAt = nil }
          .buttonStyle(.link)
          .font(.caption)
      }
      .padding(.top, 2)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
  }

  private func connectStep(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(number)")
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundColor(.white)
        .frame(width: 16, height: 16)
        .background(Circle().fill(Color.accentColor))
      Text(text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func connectClaudeCode() {
    copy(claudeCodeCommand, id: "claude-code")
    connectStartedAt = Date()
    if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
      NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
  }

  /// True when the client holds the read key but the chosen access level needs the write key.
  private func needsWriteKey(_ client: MCPConnectedClient) -> Bool {
    accessLevel != .read && client.access == "read"
  }

  @ViewBuilder
  private func connectionBadge(_ client: MCPConnectedClient?, waiting: Bool) -> some View {
    if let client, !waiting {
      // Refreshes "2 min ago" while Settings stays open.
      TimelineView(.periodic(from: .now, by: 30)) { _ in
        HStack(spacing: 4) {
          Image(systemName: needsWriteKey(client) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundColor(needsWriteKey(client) ? .orange : .green)
          Text("\(client.access == "write" ? "Connected" : "Connected, read only") · \(client.lastConnected.formatted(.relative(presentation: .named)))")
            .foregroundColor(.secondary)
        }
        .font(.caption)
      }
    } else if !waiting {
      Text("Not connected")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Setup cards

  private func setupCard(id: String, title: String, clientPrefix: String, instruction: String, code: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.callout)
          .fontWeight(.semibold)
        Spacer()
        if clients.client(matching: clientPrefix) != nil {
          connectionBadge(clients.client(matching: clientPrefix), waiting: false)
        }
        Button {
          copy(code, id: id)
        } label: {
          Label(copiedItem == id ? "Copied" : "Copy", systemImage: copiedItem == id ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
      }

      Text(instruction)
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      codeBlock(code)
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private func codeBlock(_ code: String) -> some View {
    // Shown masked: the setup holds the access key, and Settings may be on a shared screen.
    Text(masked(code))
      .font(.system(.caption, design: .monospaced))
      .foregroundColor(.secondary)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(Color(nsColor: .textBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )
  }

  // MARK: - Setup text

  /// Removes any earlier entry first, so the same command also repairs a setup after a new access
  /// key. `claude mcp add` refuses a name that already exists, and a bare remove-then-add left as
  /// two steps let users drop the working entry and never add the new one.
  private var claudeCodeCommand: String {
    "claude mcp remove --scope user \(Self.serverName) 2>/dev/null; claude mcp add --transport http --scope user \(Self.serverName) \(server.endpointURL) --header \"Authorization: Bearer \(setupToken)\""
  }

  /// `mcp-remote` bridges Claude Desktop's stdio-only local config to our HTTP endpoint. The key
  /// travels in `env` rather than in `args` — mcp-remote's documented way to pass a header value
  /// that contains a space.
  private var claudeDesktopConfig: String {
    """
    {
      "mcpServers": {
        "\(Self.serverName)": {
          "command": "npx",
          "args": ["-y", "\(Self.mcpRemotePackage)", "\(server.endpointURL)", "--header", "Authorization:${AUTH_HEADER}"],
          "env": { "AUTH_HEADER": "Bearer \(setupToken)" }
        }
      }
    }
    """
  }

  private func masked(_ code: String) -> String {
    let token = setupToken
    guard token.count > 8 else { return code }
    return code.replacingOccurrences(of: token, with: String(token.prefix(4)) + "••••••••")
  }

  private func copy(_ text: String, id: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copiedItem = id
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      if copiedItem == id { copiedItem = nil }
    }
  }
}
