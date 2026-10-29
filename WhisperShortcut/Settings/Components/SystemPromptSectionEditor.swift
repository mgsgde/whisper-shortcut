import AppKit
import SwiftUI

/// Per-mode system prompt editor backed by a single section of system-prompts.md.
///
/// Edits save themselves: shortly after typing pauses, and immediately when the view goes away,
/// a window closes or the app quits. An explicit Save button used to be the only path to disk, so
/// closing Settings after editing silently threw the prompt away and the runtime used the default.
/// Revert restores the text as it was when this page was opened.
struct SystemPromptSectionEditor: View {
  let title: LocalizedStringResource
  let systemImage: String?
  let subtitle: LocalizedStringResource
  let section: SystemPromptSection
  let defaultContent: String

  init(
    title: LocalizedStringResource,
    systemImage: String? = nil,
    subtitle: LocalizedStringResource,
    section: SystemPromptSection,
    defaultContent: String
  ) {
    self.title = title
    self.systemImage = systemImage
    self.subtitle = subtitle
    self.section = section
    self.defaultContent = defaultContent
  }

  /// Long enough not to rewrite the file on every keystroke, short enough that closing Settings
  /// right after typing is already covered before the window-close flush runs.
  private static let autosaveDelay: Duration = .milliseconds(700)

  @State private var text: String = ""
  @State private var lastSavedText: String = ""
  /// The text when the page was opened — what Revert goes back to.
  @State private var openedText: String = ""
  @State private var autosaveTask: Task<Void, Never>?
  @State private var saveFailed = false
  @State private var unreadableReason: String?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(title: title, systemImage: systemImage, subtitle: subtitle)

      if let unreadableReason {
        unreadableBanner(reason: unreadableReason)
      }

      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 200, maxHeight: 400)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(SettingsConstants.cornerRadius)
        // Edits could not be saved while the file is unreadable, so typing would only look like it worked.
        .disabled(unreadableReason != nil)
        .onChange(of: text) { _, _ in scheduleAutosave() }

      HStack(alignment: .center, spacing: 12) {
        Button(action: revert) {
          Label("Revert", systemImage: "arrow.uturn.backward")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(text == openedText || unreadableReason != nil)
        .help("Undo your edits since you opened this page")
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
        .disabled(text == defaultContent || unreadableReason != nil)
        .help("Replace with the app default prompt. The previous version is kept in system-prompts.md.bak.")
        .pointerCursorOnHover()

        Spacer(minLength: 0)

        saveStatus
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
    .onAppear { load(resetBaseline: true) }
    .onDisappear { flush() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in flush() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flush() }
    .onReceive(NotificationCenter.default.publisher(for: .contextFileDidUpdate)) { _ in
      load(resetBaseline: false)
    }
  }

  @ViewBuilder
  private var saveStatus: some View {
    if unreadableReason != nil {
      EmptyView()
    } else if saveFailed {
      Label("Not saved", systemImage: "exclamationmark.triangle.fill")
        .font(.footnote)
        .foregroundStyle(.red)
        .help("Writing system-prompts.md failed. Your text is still here; it will be retried on the next edit. Details are in the log.")
    } else if text != lastSavedText {
      Text("Saving…")
        .font(.footnote)
        .foregroundStyle(.secondary)
    } else {
      Label("Saved", systemImage: "checkmark")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .help("Changes are saved automatically")
    }
  }

  private func unreadableBanner(reason: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Your saved prompts can’t be read", systemImage: "exclamationmark.triangle.fill")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.orange)
      Text(
        "macOS blocked WhisperShortcut from reading system-prompts.md (\(reason)). Until that is fixed, the app uses its default prompts. Your file has not been changed. Give WhisperShortcut Full Disk Access in Privacy & Security, then quit and reopen the app."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
      HStack(spacing: 12) {
        Button("Open Privacy & Security") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(.bordered)
        .font(.callout)
        .pointerCursorOnHover()
        Button("Try again") { load(resetBaseline: true) }
          .buttonStyle(.bordered)
          .font(.callout)
          .pointerCursorOnHover()
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.1))
    .cornerRadius(SettingsConstants.cornerRadius)
  }

  /// Shown only for the sections the chat can actually write — Dictate Prompt via
  /// `update_app_instructions` and the glossary via `remember_dictation_term`. The remaining
  /// sections stay silent on purpose: advertising a shortcut that then does nothing is worse
  /// than not advertising it.
  private var chatEditingHint: String? {
    switch section {
    case .promptMode:
      return String(localized: "You can also change this by asking in Chat — e.g. “when I say correct, never translate”. Edits made there land in this text.")
    case .whisperGlossary:
      return String(localized: "You can also add terms by asking in Chat — e.g. “Kimi is spelled with one m”.")
    case .dictation, .chat, .readAloudRewrite:
      return nil
    }
  }

  /// Our own save comes back trimmed, and an emptied field comes back as an empty body,
  /// so neither is an outside change.
  static func isOwnSave(onDisk: String?, lastSaved: String) -> Bool {
    let onDiskBody = (onDisk ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return onDiskBody == lastSaved.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `resetBaseline` is true when the page opens: the loaded text becomes what Revert returns to.
  /// File-change notifications reload with it false and do nothing while edits are unsaved, when
  /// the disk body is our own trimmed or emptied save, or when the loaded text already matches.
  private func load(resetBaseline: Bool) {
    // Treat a missing OR empty section as "not customized" and fall back to the
    // default, matching the runtime loaders in SystemPromptsStore. A header can
    // exist with an empty body when the file predates this section and was
    // rewritten by formatContent while saving another section.
    let saved = SystemPromptsStore.shared.loadSection(section)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    unreadableReason = SystemPromptsStore.shared.unreadableReason
    let content = (saved?.isEmpty ?? true) ? defaultContent : saved!
    if !resetBaseline
      && (text != lastSavedText
        || Self.isOwnSave(onDisk: saved, lastSaved: lastSavedText)
        || content == lastSavedText) { return }
    autosaveTask?.cancel()
    lastSavedText = content
    text = content
    if resetBaseline { openedText = content }
  }

  private func scheduleAutosave() {
    guard text != lastSavedText, unreadableReason == nil else { return }
    autosaveTask?.cancel()
    autosaveTask = Task { @MainActor in
      try? await Task.sleep(for: Self.autosaveDelay)
      guard !Task.isCancelled else { return }
      save()
    }
  }

  /// Saves pending edits now (view going away, window closing, app quitting).
  private func flush() {
    autosaveTask?.cancel()
    autosaveTask = nil
    save()
  }

  private func save() {
    guard text != lastSavedText, unreadableReason == nil else { return }
    let toSave = text
    let previous = lastSavedText
    // Set before writing: the store posts `.contextFileDidUpdate` synchronously, and `load` must
    // see this text as already saved rather than reload over it.
    lastSavedText = toSave
    if SystemPromptsStore.shared.updateSection(section, content: toSave) {
      saveFailed = false
    } else {
      lastSavedText = previous
      saveFailed = true
      unreadableReason = SystemPromptsStore.shared.unreadableReason
    }
  }

  private func revert() {
    text = openedText
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
