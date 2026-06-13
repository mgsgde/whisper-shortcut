import AppKit
import SwiftUI

/// Editor for the chat's persistent user memory (UserContext/memory.md). Lets the user view, edit,
/// and clear the durable facts the model remembers. One fact per line. Reloads when the memory
/// changes underneath it (e.g. the model just called `remember_about_user`).
struct ChatMemoryEditor: View {
  @State private var text: String = ""
  @State private var lastSavedText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Memory",
        systemImage: "brain",
        subtitle:
          "Durable facts the chat remembers about you across conversations, injected into every chat. The model adds these automatically; edit or clear them here. One fact per line. Leave empty to disable."
      )

      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 120, maxHeight: 300)
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
        .help("Save changes to the memory file")
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
        .help("Forget everything the chat has remembered")
        .pointerCursorOnHover()

        Button(action: openFile) {
          Label("Open file", systemImage: "doc.badge.arrow.up")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open memory.md in the default app")
        .pointerCursorOnHover()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear { load() }
    .onReceive(NotificationCenter.default.publisher(for: .chatMemoryDidUpdate)) { _ in
      // Don't clobber unsaved edits the user is making.
      if !hasChanges { load() }
    }
  }

  private var hasChanges: Bool { text != lastSavedText }

  private func load() {
    let content = ChatMemoryStore.shared.loadMemory()
    text = content
    lastSavedText = content
  }

  private func save() {
    ChatMemoryStore.shared.saveRawText(text)
    load()
  }

  private func revert() {
    text = lastSavedText
  }

  private func clear() {
    ChatMemoryStore.shared.clear()
    load()
  }

  private func openFile() {
    let url = ChatMemoryStore.shared.memoryFileURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.open(url)
    } else {
      NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
  }
}
