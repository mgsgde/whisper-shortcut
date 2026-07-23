import AppKit
import SwiftUI

/// Editor for the chat's map of the user's shared folders (UserContext/workspace-map.md).
/// The model writes these notes as it discovers where things live; this is where the user can see
/// what it concluded, fix a wrong note, or delete the lot. One entry per line, "path — note".
struct WorkspaceMapEditor: View {
  @State private var text: String = ""
  @State private var lastSavedText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Folder Map",
        systemImage: "map",
        subtitle:
          "What the chat has learned about where things live in your shared folders, injected into every chat so it knows where to look. The model writes these itself; edit or clear them here. One entry per line, \"path — note\"."
      )

      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 100, maxHeight: 260)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(SettingsConstants.cornerRadius)

      HStack(alignment: .center, spacing: 12) {
        Button(action: save) {
          Label("Save", systemImage: "square.and.arrow.down")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(!hasChanges)
        .help("Save changes to the folder map")
        .pointerCursorOnHover()

        Button(action: revert) {
          Label("Revert", systemImage: "arrow.uturn.backward")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(!hasChanges)
        .help("Discard unsaved changes")
        .pointerCursorOnHover()

        Button(action: clear) {
          Label("Clear all", systemImage: "trash")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Forget everything the chat has learned about your folder layout")
        .pointerCursorOnHover()

        Button(action: openFile) {
          Label("Open file", systemImage: "doc.badge.arrow.up")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open workspace-map.md in the default app")
        .pointerCursorOnHover()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear { load() }
    .onReceive(NotificationCenter.default.publisher(for: .workspaceMapDidUpdate)) { _ in
      // Don't clobber unsaved edits the user is making.
      if !hasChanges { load() }
    }
  }

  private var hasChanges: Bool { text != lastSavedText }

  private func load() {
    let content = WorkspaceMapStore.shared.loadMap()
    text = content
    lastSavedText = content
  }

  private func save() {
    WorkspaceMapStore.shared.saveRawText(text)
    load()
  }

  private func revert() {
    text = lastSavedText
  }

  private func clear() {
    WorkspaceMapStore.shared.clear()
    load()
  }

  private func openFile() {
    let url = WorkspaceMapStore.shared.mapFileURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.open(url)
    } else {
      NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
  }
}
