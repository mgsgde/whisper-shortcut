import SwiftUI

/// A one-time tip in the empty chat: most users never find out that Claude Code, Claude Desktop
/// or Codex can read their meetings and tune their dictation over MCP. It sits under the shortcut
/// list, where a new chat has plenty of empty space, and goes away for good once any AI app has
/// connected or the user closes it. Hidden in Offline Mode, where the MCP server is off.
struct ChatMCPTipView: View {
  @ObservedObject private var registry = MCPClientRegistry.shared
  @AppStorage(UserDefaultsKeys.chatMCPTipDismissed) private var dismissed = false
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false

  var body: some View {
    if !dismissed && !offlineMode && registry.clients.isEmpty {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 15))
          .foregroundColor(ChatTheme.secondaryText)
          .padding(.top, 2)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 6) {
          Text("Use WhisperShortcut from Claude")
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(ChatTheme.primaryText)
          Text(
            "Connect Claude Code, Claude Desktop or Codex. Ask them about a meeting while it records, or let them tune your dictation: they read your recent dictations, already know the names you use, and suggest fixes that you approve."
          )
          .font(.callout)
          .foregroundColor(ChatTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)

          Button {
            SettingsManager.shared.showSettings(tab: .aiApps)
          } label: {
            Label("Connect an AI App", systemImage: "arrow.right.circle")
              .font(.callout)
              .foregroundColor(ChatTheme.primaryText)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(ChatTheme.windowBackground)
              .clipShape(RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .pointerCursorOnHover()
          .padding(.top, 4)
        }

        Spacer(minLength: 0)

        Button {
          dismissed = true
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(ChatTheme.secondaryText)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide this tip")
        .accessibilityLabel(Text("Hide this tip"))
        .pointerCursorOnHover()
      }
      .padding(14)
      .frame(maxWidth: 560, alignment: .leading)
      .background(ChatTheme.controlBackground)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(ChatTheme.primaryText.opacity(ChatTheme.borderOpacity), lineWidth: 1)
      )
    }
  }
}
