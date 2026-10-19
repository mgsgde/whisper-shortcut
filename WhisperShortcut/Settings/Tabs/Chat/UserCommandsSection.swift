import AppKit
import SwiftUI

/// Settings UI for user-defined chat commands (`UserContext/commands/*.md`).
///
/// The files are the source of truth and are edited in any text editor; this section only lists
/// what the app understood, says what it could not read, and creates a starting file. There is
/// deliberately no editor here — whoever sets the app up for a team writes the files once.
struct UserCommandsSection: View {
  @ObservedObject private var store = UserCommandStore.shared
  @State private var createError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Commands",
        systemImage: "command",
        subtitle:
          "Your own one-click instructions. Each Markdown file in the commands folder becomes a slash command in the chat. Commands for meetings also get a button above the meeting chat's message field."
      )

      if store.commands.isEmpty && store.issues.isEmpty {
        Text(
          "No commands yet. Create one from the template, or put .md files into the commands folder."
        )
        .font(.callout)
        .foregroundColor(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(store.commands) { command in
            commandRow(command)
          }
          ForEach(store.issues) { issue in
            issueRow(issue)
          }
        }
      }

      HStack(spacing: 8) {
        Button("New Command…") { createCommand() }
          .pointerCursorOnHover()
        Button("Open Commands Folder") { openFolder() }
          .pointerCursorOnHover()
        Button("Reload") { store.reload() }
          .pointerCursorOnHover()
          .help("Re-read the folder. The chat also re-reads it whenever its window comes forward.")
        Spacer()
      }

      if let createError {
        Text(createError)
          .font(.caption)
          .foregroundColor(.orange)
      }

      Text(
        "File name = command name (anamnesis.md → /anamnesis). Optional header lines: label (button text), description, scope (meeting, chat or both). Everything below the header is sent to the selected chat model as your message — offline models included. In a meeting chat the model also sees the full transcript."
      )
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear { store.reload() }
  }

  private func commandRow(_ command: UserCommand) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(command.slash)
        .font(.system(.callout, design: .monospaced))
        .fontWeight(.medium)
        .frame(minWidth: 110, alignment: .leading)

      VStack(alignment: .leading, spacing: 2) {
        Text(command.label)
          .font(.callout)
        if !command.description.isEmpty {
          Text(command.description)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(2)
        }
      }

      Spacer()

      scopeBadge(command.scope)

      Button("Edit") { NSWorkspace.shared.open(command.fileURL) }
        .pointerCursorOnHover()
        .help("Open \(command.fileURL.lastPathComponent) in your default editor")
    }
  }

  private func issueRow(_ issue: UserCommandIssue) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.fileName)
          .font(.system(.callout, design: .monospaced))
        Text(issue.isWarning ? "\(issue.message) — loaded anyway." : "\(issue.message) — not loaded.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button("Edit") {
        NSWorkspace.shared.open(store.directoryURL.appendingPathComponent(issue.fileName))
      }
      .pointerCursorOnHover()
    }
  }

  private func scopeBadge(_ scope: UserCommandScope) -> some View {
    let text: String
    switch scope {
    case .meeting: text = "Meeting"
    case .chat: text = "Chat"
    case .both: text = "Chat + Meeting"
    }
    return Text(text)
      .font(.caption2)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.secondary.opacity(0.15)))
  }

  private func createCommand() {
    do {
      let url = try store.createFromTemplate()
      createError = nil
      store.reload()
      NSWorkspace.shared.open(url)
    } catch {
      createError = "Could not create the file: \(error.localizedDescription)"
    }
  }

  private func openFolder() {
    AppSupportPaths.ensureDirectoryExists(store.directoryURL)
    NSWorkspace.shared.open(store.directoryURL)
  }
}
