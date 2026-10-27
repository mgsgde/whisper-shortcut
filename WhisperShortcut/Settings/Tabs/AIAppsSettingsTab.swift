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
  @State private var connectOutcome: [MCPClient: ConnectOutcome] = [:]
  @State private var connecting: MCPClient?

  private enum ConnectOutcome: Equatable {
    case connected
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
          setupCard(
            .claudeCode,
            manualInstruction: "Run in Terminal, then start a new Claude Code session:",
            code: claudeCodeCommand
          )

          setupCard(
            .claudeDesktop,
            note: "Needs Node.js.",
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
          ? ("So you can ask \"why did it get that wrong?\" and the AI app looks at what you dictated in the last 7 days." as LocalizedStringKey)
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
      return String(localized: "AI apps can read meetings and your setup, never change anything.")
    case .propose:
      return String(localized: "Each change opens here for you to accept, edit or decline. New glossary terms are added right away, since they never replace anything. Connect your AI app again below so it gets the new access.")
    case .apply:
      return String(localized: "Changes apply at once and can be undone below. Dictation and Chat instructions still wait for your approval: a meeting or email an AI app reads could contain text meant to change them. Connect your AI app again below so it gets the new access.")
    }
  }

  private var privacyNote: String {
    let what = accessLevel == .read
      ? String(localized: "AI apps can read transcripts, notes, summaries and your setup, never change or delete them.")
      : String(localized: "AI apps can read your meetings and setup and change the glossary, instructions, writing style and commands. API keys are never shared.")
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
        connectButton(client)
      }

      switch connectOutcome[client] {
      case .connected:
        Label("Connected. \(client.restartHint)", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundColor(.green)
          .fixedSize(horizontal: false, vertical: true)
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundColor(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      case nil:
        EmptyView()
      }

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
        Text(connectOutcome[client] == .connected ? ("Connect Again" as LocalizedStringKey) : "Connect")
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.small)
    // Not gated on the server running: the entry only needs the address and key, and the app
    // connects as soon as the server is up.
    .disabled(connecting != nil || setupToken.isEmpty)
    .help(Text("Adds WhisperShortcut to \(client.displayName)'s settings. macOS asks once for access to the folder they live in."))
    .pointerCursorOnHover()
  }

  private func connect(_ client: MCPClient) {
    connecting = client
    Task { @MainActor in
      let result = await MCPClientInstaller.connect(
        client, url: server.endpointURL, token: setupToken,
        mcpRemotePackage: Self.mcpRemotePackage, serverName: Self.serverName)
      connecting = nil
      switch result {
      case .success:
        connectOutcome[client] = .connected
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
