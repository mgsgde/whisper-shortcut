import AppKit
import SwiftUI

/// Settings UI for the folders the chat may read from.
///
/// Picking a folder here is what actually grants the sandboxed app access to it — the
/// NSOpenPanel hands us a security-scoped bookmark that `WorkspaceFolders` persists. Nothing
/// outside these folders is readable, in either build.
struct WorkspaceFoldersSection: View {
  @State private var folderPaths: [String] = WorkspaceFolders.displayPaths

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Workspace Folders",
        systemImage: "folder",
        subtitle:
          "Folders the chat may read — list files, open text files, and search them. Read-only; nothing outside these folders is accessible."
      )

      if folderPaths.isEmpty {
        Text("No folders shared. The chat cannot read any files on your Mac.")
          .font(.callout)
          .foregroundColor(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(folderPaths, id: \.self) { path in
            HStack(spacing: 12) {
              Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)

              Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

              Spacer()

              Button("Remove") {
                WorkspaceFolders.removeFolder(displayPath: path)
                folderPaths = WorkspaceFolders.displayPaths
              }
              .pointerCursorOnHover()
            }
          }
        }
      }

      HStack {
        Button("Add Folder…") {
          addFolder()
        }
        .pointerCursorOnHover()

        Spacer()
      }

      Text(
        "The chat sees file names and text content in these folders, and sends what it reads to your selected chat model. Only share folders you are comfortable with."
      )
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      // Only meaningful once something is shared — an empty map with no folders is noise.
      if !folderPaths.isEmpty {
        SpacedSectionDivider()
        WorkspaceMapEditor()
      }
    }
  }

  private func addFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Share"
    panel.message = "Choose folders the chat may read"
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      WorkspaceFolders.addFolder(url)
    }
    folderPaths = WorkspaceFolders.displayPaths
  }
}
