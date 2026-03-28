import AppKit
import SwiftUI

/// Context tab: context data, system prompts, and settings.
struct ContextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var saveUsageData = false
  @State private var showDeleteInteractionConfirmation = false

  @State private var systemPromptsText: String = ""
  @State private var lastSavedSystemPromptsText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      contextDataSection

      SpacedSectionDivider()

      systemPromptsOverviewSection
    }
    .confirmationDialog("Delete context data?", isPresented: $showDeleteInteractionConfirmation, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        viewModel.deleteInteractionData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("All interaction data and everything in context files will be deleted. System prompts will be recreated with defaults. Settings are preserved. Continue?")
    }
    .onAppear {
      let content = SystemPromptsStore.shared.loadFullContent()
      systemPromptsText = content
      lastSavedSystemPromptsText = content
    }
    .onReceive(NotificationCenter.default.publisher(for: .contextFileDidUpdate)) { _ in
      let content = SystemPromptsStore.shared.loadFullContent()
      systemPromptsText = content
      lastSavedSystemPromptsText = content
    }
  }

  // MARK: - Context data (top)
  @ViewBuilder
  private var contextDataSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Context data",
        subtitle: "Interaction logs, context data, and suggested prompts are stored here. You can open the folder or delete all of this data; settings are preserved."
      )

      HStack(alignment: .center, spacing: 12) {
        Button(action: { viewModel.openContextFolder() }) {
          Label("Open context data", systemImage: "folder")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open context data in Finder")
        .pointerCursorOnHover()

        Button("Delete context data", role: .destructive) {
          showDeleteInteractionConfirmation = true
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .help("Only delete interaction history and context; settings are preserved")
        .pointerCursorOnHover()
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Toggle("Save usage data", isOn: $saveUsageData)
        .toggleStyle(.checkbox)
        .help("When enabled, interaction logs (dictation, prompt mode, Open Gemini chat) are stored for context. Disabled by default.")
    }
  }

  // MARK: - System prompts (single file editor)
  @ViewBuilder
  private var systemPromptsOverviewSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "System prompts",
        subtitle: "All system prompts in one file. Edit the sections between the === headers. Save to apply."
      )

      Text("Edit sections: Dictation (Speech-to-Text), Prompt Mode.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      TextEditor(text: $systemPromptsText)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 320, maxHeight: 500)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(SettingsConstants.cornerRadius)

      HStack(alignment: .center, spacing: 12) {
        Button(action: saveSystemPrompts) {
          Label("Save", systemImage: "square.and.arrow.down")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(systemPromptsText == lastSavedSystemPromptsText)
        .help("Save changes to the system prompts file")
        .pointerCursorOnHover()

        Button(action: revertSystemPrompts) {
          Label("Revert", systemImage: "arrow.uturn.backward")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(systemPromptsText == lastSavedSystemPromptsText)
        .help("Discard unsaved changes and reload from file")
        .pointerCursorOnHover()

        Button(action: openSystemPromptsFile) {
          Label("Open file", systemImage: "doc.badge.arrow.up")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open system-prompts.md in the default app")
        .pointerCursorOnHover()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func revertSystemPrompts() {
    systemPromptsText = lastSavedSystemPromptsText
  }

  private func openSystemPromptsFile() {
    let url = SystemPromptsStore.shared.systemPromptsFileURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.open(url)
    } else {
      NSWorkspace.shared.open(SystemPromptsStore.shared.systemPromptsFileURL.deletingLastPathComponent())
    }
  }

  private func saveSystemPrompts() {
    SystemPromptsStore.shared.saveFullContent(systemPromptsText)
    lastSavedSystemPromptsText = systemPromptsText
    NotificationCenter.default.post(name: .contextFileDidUpdate, object: nil)
  }
}
