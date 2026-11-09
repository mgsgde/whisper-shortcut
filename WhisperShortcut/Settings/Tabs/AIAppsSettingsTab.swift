import AppKit
import SwiftUI

/// Claude & AI Apps Settings Tab — the local MCP server (`MCPServer`): lets Claude Code, Claude
/// Desktop and other MCP clients on this Mac read meeting transcripts, including the one recording
/// right now, and, if the user allows it, set up WhisperShortcut for them (glossary, instructions,
/// writing style, commands).
///
/// Its own tab rather than a section under Meetings: half of what it does is setting up dictation,
/// which nobody looked for under Meetings.
///
/// Off by default. When on, it shows a ready-to-paste setup for the two clients we test against,
/// both carrying the access key, so connecting is one copy and one paste. The key in the setup
/// follows the access level: the read key while AI apps may only read, the write key otherwise.
struct AIAppsSettingsTab: View {
  @ObservedObject private var server = MCPServer.shared
  @ObservedObject private var proposals = MCPProposalStore.shared
  @ObservedObject private var changeLog = MCPChangeLog.shared
  @ObservedObject private var clients = MCPClientRegistry.shared

  @AppStorage(UserDefaultsKeys.mcpConfigAccessLevel) private var accessLevelRaw = MCPConfigAccessLevel.read.rawValue
  @AppStorage(UserDefaultsKeys.mcpShareRecentInteractions) private var shareRecentInteractions = false
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var contextLoggingEnabled = false

  /// Changes listed under "Changed by AI apps"; the full record stays in `mcp-changes.jsonl`.
  private static let visibleChanges = 5

  private static let serverName = "whisper-shortcut"

  @State private var copiedItem: String?
  @State private var showRegenerateConfirm = false
  @State private var undoMessage: String?
  @State private var showAllChanges = false
  @State private var connectOutcome: [MCPClient: ConnectOutcome] = [:]
  /// When Connect last wrote each client's config; until the client's next `initialize` the card
  /// says it is waiting instead of showing a connection that still holds the old entry.
  @State private var connectedAt: [MCPClient: Date] = [:]
  @State private var connecting: MCPClient?
  @State private var disconnecting: MCPClient?

  private enum ConnectOutcome: Equatable {
    case connected
    /// `removed` is false when the entry was already gone, so the card can say so honestly.
    case disconnected(removed: Bool)
    case failed(String)
  }

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
        title: "Claude & AI Apps",
        systemImage: "point.3.connected.trianglepath.dotted",
        subtitle: "Connect Claude and other AI apps on this Mac to WhisperShortcut. They can set it up for you from what they already know about you: names for the glossary, how your messages should sound, your commands. And they can read your meetings, including the one recording right now."
      )

      Toggle("Allow AI apps on this Mac to connect", isOn: Binding(
        get: { server.isEnabled },
        set: { server.isEnabled = $0 }
      ))
      .toggleStyle(.switch)

      statusRow

      if server.isEnabled {
        accessPicker

        VStack(alignment: .leading, spacing: 10) {
          if AppConstants.isSidecarInstance {
            Label("Test build: Connect is off here, so it can't overwrite the setup of the WhisperShortcut you use every day.", systemImage: "testtube.2")
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          setupCard(
            .claudeCode,
            note: "Anthropic's agent, in Terminal and in the Code tab of the Claude app.",
            manualInstruction: "Run in Terminal, then start a new Claude Code session:",
            code: claudeCodeCommand
          )

          setupCard(
            .claudeDesktop,
            note: "The regular chat in the Claude app.",
            manualInstruction: "In Claude, open Settings → Developer → Edit Config, paste this into claude_desktop_config.json (merge it with any servers already there), then quit and reopen Claude.",
            code: claudeDesktopConfig
          )

          setupCard(
            .codex,
            note: "OpenAI's agent. ChatGPT itself can't reach apps on your Mac, Codex can.",
            manualInstruction: "Add this to ~/.codex/config.toml, then start a new Codex session:",
            code: codexConfig
          )
        }

        if accessLevel != .read {
          pendingProposals
          recentChanges
        }

        Text(privacyNote)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Button("New access key…") { showRegenerateConfirm = true }
          Text("Apps you already connected stop working until you connect them again.")
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
          }
        } message: {
          Text("Claude and other apps connected with the current key lose access until you connect them again.")
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
          ? ("So you can ask \"why did it get that wrong?\" and the AI app looks at what you dictated recently (the last 7 days, or up to 90 when it asks for more)." as LocalizedStringKey)
          : "Needs \"Save usage data\" in Privacy & Permissions. Then you can ask \"why did it get that wrong?\" and the AI app looks at your recent dictations.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var accessCaption: String {
    switch accessLevel {
    case .read:
      return String(localized: "AI apps can read meetings and your setup, never change anything.")
    case .propose:
      return String(localized: "Each change opens here for you to accept, edit or decline. Connect your AI app again below so it gets the new access.")
    case .apply:
      return String(localized: "Changes apply at once and can be undone below. Instructions, model changes and screenshot context still wait for your approval: a meeting or email an AI app reads could contain text meant to change them. Connect your AI app again below so it gets the new access.")
    }
  }

  private var privacyNote: String {
    let what = accessLevel == .read
      ? String(localized: "AI apps can read transcripts, notes, summaries and your setup, never change or delete them.")
      : String(localized: "AI apps can read your meetings and setup and change the glossary, instructions, writing style, commands and app settings such as models and shortcuts. API keys are never shared.")
    return what + " " + String(localized: "Only apps set up with your access key get in, and nothing is reachable from other devices. What you read in an AI app is sent to that app's provider.")
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
          Button(showAllChanges ? ("Show fewer" as LocalizedStringKey) : "Show all \(all.count)") { showAllChanges.toggle() }
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
      undoMessage = String(localized: "\(MCPProposalWindows.title(for: change)) was changed again after this, so it was left as it is. Edit it in Settings instead.")
    case .notFound:
      undoMessage = String(localized: "This change is no longer on record.")
    case .failed(let message):
      undoMessage = String(localized: "Couldn't undo: \(message)")
    case .undonePartial(let skipped):
      let list = skipped.joined(separator: ", ")
      undoMessage = String(localized: "Restored, except: \(list). They are no longer valid.")
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
        Text(server.isEnabled ? ("Starting…" as LocalizedStringKey) : "Off")
          .font(.callout)
          .foregroundColor(.secondary)
      }
    }
  }

  // MARK: - Setup cards

  /// One click writes the client's config itself (`MCPClientInstaller`); the copy-paste setup stays
  /// behind "Set up by hand" for people who keep their configs elsewhere or prefer to paste.
  private func setupCard(_ client: MCPClient, note: LocalizedStringKey? = nil, manualInstruction: LocalizedStringKey, code: String) -> some View {
    let id = client.rawValue
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(client.displayName)
            .font(.callout)
            .fontWeight(.semibold)
          if let note {
            Text(note)
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer()
        HStack(spacing: 8) {
          if isConnected(client) { disconnectButton(client) }
          connectButton(client)
        }
      }

      connectionStatus(client)

      DisclosureGroup("Set up by hand") {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .top) {
            Text(manualInstruction)
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
              copy(code, id: id)
            } label: {
              Label(copiedItem == id ? ("Copied" as LocalizedStringKey) : "Copy", systemImage: copiedItem == id ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
          }

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
        .padding(.top, 6)
      }
      .font(.caption)
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private func connectButton(_ client: MCPClient) -> some View {
    Button {
      connect(client)
    } label: {
      if connecting == client {
        ProgressView().controlSize(.small)
      } else {
        Text(isConnected(client) ? ("Connect Again" as LocalizedStringKey) : "Connect")
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.small)
    // Not gated on the server running: the entry only needs the address and key, and the app
    // connects as soon as the server is up.
    // A test build runs next to the user's own instance with its own key and never starts the
    // server, so a Connect from it would point the user's real AI app at the wrong key.
    .disabled(connecting != nil || disconnecting != nil || setupToken.isEmpty || AppConstants.isSidecarInstance)
    .help(Text("Adds WhisperShortcut to \(client.displayName)'s settings. macOS asks once for access to the folder they live in."))
    .pointerCursorOnHover()
  }

  /// Connected means: Connect wrote the entry this session, or the client has called in since.
  /// A Disconnect in this session wins over an old registry record.
  private func isConnected(_ client: MCPClient) -> Bool {
    switch connectOutcome[client] {
    case .connected: return true
    case .disconnected: return false
    default: return clients.client(matching: client.registryPrefix) != nil
    }
  }

  /// Secondary to Connect Again: removing access is the rarer move, so it does not compete for
  /// attention. No confirmation, since Connect puts it back in one click.
  private func disconnectButton(_ client: MCPClient) -> some View {
    Button {
      disconnect(client)
    } label: {
      if disconnecting == client {
        ProgressView().controlSize(.small)
      } else {
        Text("Disconnect")
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(connecting != nil || disconnecting != nil || AppConstants.isSidecarInstance)
    .help(Text("Removes WhisperShortcut from \(client.displayName)'s settings. macOS asks once for access to the folder they live in."))
    .pointerCursorOnHover()
  }

  /// One line under the client's name: the live connection from `MCPClientRegistry` once the app
  /// has called in, "waiting" right after Connect wrote its config, or why Connect failed.
  @ViewBuilder
  private func connectionStatus(_ client: MCPClient) -> some View {
    let seen = clients.client(matching: client.registryPrefix)
    let waiting = connectedAt[client].map { started in seen.map { $0.lastConnected < started } ?? true } ?? false
    if case .failed(let message) = connectOutcome[client] {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundColor(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    } else if case .disconnected(let removed) = connectOutcome[client] {
      Label {
        Text(removed
          ? "Removed from \(client.displayName)'s settings. \(client.restartHint)"
          : "WhisperShortcut wasn't in \(client.displayName)'s settings.")
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "minus.circle").foregroundColor(.secondary)
      }
      .font(.caption)
    } else if waiting {
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Added to \(client.displayName)'s settings. \(client.restartHint) Waiting for it to connect…")
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.caption)
    } else if let seen {
      let readOnlyTrap = accessLevel != .read && seen.access == "read"
      // Refreshes "2 min ago" while Settings stays open.
      TimelineView(.periodic(from: .now, by: 30)) { _ in
        VStack(alignment: .leading, spacing: 2) {
          Label {
            Text("\(seen.access == "write" ? String(localized: "Connected") : String(localized: "Connected, read only")) · \(seen.lastConnected.formatted(.relative(presentation: .named)))")
              .foregroundColor(.secondary)
          } icon: {
            Image(systemName: readOnlyTrap ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
              .foregroundColor(readOnlyTrap ? .orange : .green)
          }
          if readOnlyTrap {
            Text("\(client.displayName) holds the read-only key, so it can't suggest or make changes. Click Connect Again.")
              .foregroundColor(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .font(.caption)
      }
    }
  }

  private func connect(_ client: MCPClient) {
    connecting = client
    Task { @MainActor in
      let result = await MCPClientInstaller.connect(
        client, url: server.endpointURL, token: setupToken, serverName: Self.serverName)
      connecting = nil
      switch result {
      case .success:
        connectOutcome[client] = .connected
        connectedAt[client] = Date()
      case .failure(let error):
        if case .cancelled? = error as? MCPClientInstallerError { return }
        connectOutcome[client] = .failed(error.localizedDescription)
      }
    }
  }

  private func disconnect(_ client: MCPClient) {
    disconnecting = client
    Task { @MainActor in
      let result = await MCPClientInstaller.disconnect(client, serverName: Self.serverName)
      disconnecting = nil
      switch result {
      case .success(let removed):
        // Forget the last call-in too, or the card would keep showing "Connected · 2 min ago".
        clients.forget(matching: client.registryPrefix)
        connectedAt[client] = nil
        connectOutcome[client] = .disconnected(removed: removed)
      case .failure(let error):
        if case .cancelled? = error as? MCPClientInstallerError { return }
        connectOutcome[client] = .failed(error.localizedDescription)
      }
    }
  }

  // MARK: - Setup text

  /// Removes any earlier entry first, so the same command also repairs a setup after a new access
  /// key. `claude mcp add` refuses a name that already exists, and a bare remove-then-add left as
  /// two steps let users drop the working entry and never add the new one.
  private var claudeCodeCommand: String {
    "claude mcp remove --scope user \(Self.serverName) 2>/dev/null; claude mcp add --transport http --scope user \(Self.serverName) \(server.endpointURL) --header \"Authorization: Bearer \(setupToken)\""
  }

  /// Claude Desktop only launches local MCP servers as stdio processes. This app's binary is the
  /// bridge (`--mcp-stdio`): it reads JSON-RPC on stdin and forwards it to the HTTP endpoint.
  /// The access key travels in the environment, not on the command line.
  private var claudeDesktopConfig: String {
    let executable = Bundle.main.executablePath
      ?? "/Applications/WhisperShortcut.app/Contents/MacOS/WhisperShortcut"
    return """
    {
      "mcpServers": {
        "\(Self.serverName)": {
          "command": "\(executable)",
          "args": ["\(MCPStdioBridge.argument)"],
          "env": {
            "\(MCPStdioBridge.urlEnv)": "\(server.endpointURL)",
            "\(MCPStdioBridge.authEnv)": "Bearer \(setupToken)"
          }
        }
      }
    }
    """
  }

  private var codexConfig: String {
    """
    [mcp_servers.\(Self.serverName)]
    url = "\(server.endpointURL)"
    http_headers = { Authorization = "Bearer \(setupToken)" }
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
