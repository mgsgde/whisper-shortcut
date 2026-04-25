import AppKit
import SwiftUI

/// Per-mode system prompt editor backed by a single section of system-prompts.md.
/// Provides Save, Revert, and Open File buttons.
struct SystemPromptSectionEditor: View {
  let title: String
  let subtitle: String
  let section: SystemPromptSection
  let defaultContent: String

  @State private var text: String = ""
  @State private var lastSavedText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(title: title, subtitle: subtitle)

      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 200, maxHeight: 400)
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
        .help("Save changes to the system prompts file")
        .pointerCursorOnHover()

        Button(action: revert) {
          Label("Revert", systemImage: "arrow.uturn.backward")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(!hasChanges)
        .help("Discard unsaved changes and restore the last saved text")
        .pointerCursorOnHover()

        Button(action: openFile) {
          Label("Open file", systemImage: "doc.badge.arrow.up")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open system-prompts.md in the default app")
        .pointerCursorOnHover()

        Button("Reset to default") {
          text = defaultContent
        }
        .buttonStyle(.bordered)
        .font(.callout)
        .disabled(text == defaultContent)
        .help("Replace with the app default prompt")
        .pointerCursorOnHover()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear { load() }
    .onReceive(NotificationCenter.default.publisher(for: .contextFileDidUpdate)) { _ in
      load()
    }
  }

  private var hasChanges: Bool { text != lastSavedText }

  private func load() {
    let content = SystemPromptsStore.shared.loadSection(section)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultContent
    text = content
    lastSavedText = content
  }

  private func save() {
    SystemPromptsStore.shared.updateSection(section, content: text)
    lastSavedText = text
  }

  private func revert() {
    text = lastSavedText
  }

  private func openFile() {
    let url = SystemPromptsStore.shared.systemPromptsFileURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.open(url)
    } else {
      NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
  }
}
