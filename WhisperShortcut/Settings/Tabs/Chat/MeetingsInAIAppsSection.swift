import AppKit
import SwiftUI

/// Settings UI for the local MCP server (`MCPServer`): lets Claude Code, Claude Desktop and other
/// MCP clients on this Mac read meeting transcripts, including the one recording right now.
///
/// Off by default. When on, it shows a ready-to-paste setup for the two clients we test against,
/// both carrying the access key, so connecting is one copy and one paste.
struct MeetingsInAIAppsSection: View {
  @ObservedObject private var server = MCPServer.shared

  /// Pinned so a new `mcp-remote` release can't change what users paste. Bump deliberately.
  private static let mcpRemotePackage = "mcp-remote@0.14.3"
  private static let serverName = "whisper-shortcut"

  @State private var copiedItem: String?
  @State private var showRegenerateConfirm = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Meetings in Claude & Other AI Apps",
        systemImage: "point.3.connected.trianglepath.dotted",
        subtitle: "Let Claude and other MCP apps on this Mac read your meeting transcripts, including the meeting that is recording right now. Instead of pasting the transcript, ask \"what was just said about the budget?\" and the app fetches what's new."
      )

      Toggle("Allow AI apps on this Mac to read meetings", isOn: Binding(
        get: { server.isEnabled },
        set: { server.isEnabled = $0 }
      ))
      .toggleStyle(.switch)

      statusRow

      if server.isEnabled {
        setupCard(
          id: "claude-code",
          title: "Claude Code",
          instruction: "Run in Terminal, then start a new Claude Code session. Run it again after a new access key:",
          code: claudeCodeCommand
        )

        setupCard(
          id: "claude-desktop",
          title: "Claude Desktop",
          instruction: "In Claude, open Settings → Developer → Edit Config, paste this into claude_desktop_config.json (merge it with any servers already there), then quit and reopen Claude. Needs Node.js.",
          code: claudeDesktopConfig
        )

        Text("Read-only: AI apps can read transcripts, notes and summaries, never change or delete them. Only apps set up with your access key get in, and nothing is reachable from other devices. What you read in an AI app is sent to that app's provider.")
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
          Button("Create New Key", role: .destructive) { server.regenerateToken() }
        } message: {
          Text("Claude and other apps set up with the current key lose access until you copy the new setup into them.")
        }
      }
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

  // MARK: - Setup cards

  private func setupCard(id: String, title: String, instruction: String, code: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.callout)
          .fontWeight(.semibold)
        Spacer()
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
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  // MARK: - Setup text

  /// Removes any earlier entry first, so the same command also repairs a setup after a new access
  /// key. `claude mcp add` refuses a name that already exists, and a bare remove-then-add left as
  /// two steps let users drop the working entry and never add the new one.
  private var claudeCodeCommand: String {
    "claude mcp remove --scope user \(Self.serverName) 2>/dev/null; claude mcp add --transport http --scope user \(Self.serverName) \(server.endpointURL) --header \"Authorization: Bearer \(server.token())\""
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
          "env": { "AUTH_HEADER": "Bearer \(server.token())" }
        }
      }
    }
    """
  }

  private func masked(_ code: String) -> String {
    let token = server.token()
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
