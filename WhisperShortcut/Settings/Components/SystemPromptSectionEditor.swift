import AppKit
import SwiftUI

/// Per-mode system prompt editor backed by a single section of system-prompts.md.
/// Provides Save, Revert, and Open File buttons.
struct SystemPromptSectionEditor: View {
  let title: String
  let systemImage: String?
  let subtitle: String
  let section: SystemPromptSection
  let defaultContent: String

  init(
    title: String,
    systemImage: String? = nil,
    subtitle: String,
    section: SystemPromptSection,
    defaultContent: String
  ) {
    self.title = title
    self.systemImage = systemImage
    self.subtitle = subtitle
    self.section = section
    self.defaultContent = defaultContent
  }

  @State private var text: String = ""
  @State private var lastSavedText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(title: title, systemImage: systemImage, subtitle: subtitle)

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

      // Surfaced here rather than in onboarding: someone editing a system prompt by hand already
      // has exactly the intent this shortcut serves, so it teaches the feature at the moment it
      // is wanted instead of announcing it when the need is still abstract.
      if let hint = chatEditingHint {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "bubble.left.and.text.bubble.right")
            .foregroundStyle(.secondary)
          Text(hint)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("Open Chat") { ChatWindowManager.shared.show() }
            .buttonStyle(.link)
            .font(.footnote)
            .pointerCursorOnHover()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onAppear { load() }
    .onReceive(NotificationCenter.default.publisher(for: .contextFileDidUpdate)) { _ in
      load()
    }
  }

  private var hasChanges: Bool { text != lastSavedText }

  /// Shown only for the sections the chat can actually write — Dictate Prompt via
  /// `update_app_instructions` and the glossary via `remember_dictation_term`. The remaining
  /// sections stay silent on purpose: advertising a shortcut that then does nothing is worse
  /// than not advertising it.
  private var chatEditingHint: String? {
    switch section {
    case .promptMode:
      return "You can also change this by asking in Chat — e.g. “when I say correct, never translate”. Edits made there land in this text."
    case .whisperGlossary:
      return "You can also add terms by asking in Chat — e.g. “Kimi is spelled with one m”."
    case .dictation, .chat, .readAloudRewrite:
      return nil
    }
  }

  private func load() {
    // Treat a missing OR empty section as "not customized" and fall back to the
    // default, matching the runtime loaders in SystemPromptsStore. A header can
    // exist with an empty body when the file predates this section and was
    // rewritten by formatContent while saving another section.
    let saved = SystemPromptsStore.shared.loadSection(section)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let content = (saved?.isEmpty ?? true) ? defaultContent : saved!
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
