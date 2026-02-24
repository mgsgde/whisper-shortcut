import AppKit
import SwiftUI

/// Context tab: context data, system prompts, and Smart Improvement settings.
struct ContextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var selectedInterval: AutoImprovementInterval = .default
  @State private var showDeleteInteractionConfirmation = false
  @State private var isImprovementRunning = false

  @State private var systemPromptsText: String = ""
  @State private var lastSavedSystemPromptsText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      contextDataSection

      SpacedSectionDivider()

      systemPromptsOverviewSection

      SpacedSectionDivider()

      smartImprovementSection

      SpacedSectionDivider()

      usageInstructionsSection
    }
    .confirmationDialog("Delete context data?", isPresented: $showDeleteInteractionConfirmation, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        viewModel.deleteInteractionData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("All interaction data and everything in context files will be deleted. System prompts will be recreated with defaults. Settings are preserved. Continue?")
    }
  }

  // MARK: - Context data (top)
  @ViewBuilder
  private var contextDataSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Context data",
        subtitle: "Interaction logs, user context, and suggested prompts are stored here. You can open the folder or delete all of this data; settings are preserved."
      )

      HStack(alignment: .center, spacing: 12) {
        Button(action: { viewModel.openUserContextFolder() }) {
          Label("Open context data", systemImage: "folder")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open context data in Finder")

        Button("Delete context data", role: .destructive) {
          showDeleteInteractionConfirmation = true
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .help("Only delete interaction history and context; settings are preserved")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
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

      Text("Edit sections: Dictation (Speech-to-Text), Dictate Prompt, Prompt & Read.")
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

        Button(action: revertSystemPrompts) {
          Label("Revert", systemImage: "arrow.uturn.backward")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(systemPromptsText == lastSavedSystemPromptsText)
        .help("Discard unsaved changes and reload from file")

        Button(action: openSystemPromptsFile) {
          Label("Open file", systemImage: "doc.badge.arrow.up")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open system-prompts.md in the default app")
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
    NotificationCenter.default.post(name: .userContextFileDidUpdate, object: nil)
  }

  // MARK: - Smart Improvement
  @ViewBuilder
  private var smartImprovementSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Smart Improvement",
        subtitle: "Improve from voice shortcut and automatic improvement based on your usage"
      )

      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          ShortcutInputRow(
            label: "Improve from voice:",
            placeholder: "e.g., command+6",
            text: $viewModel.data.togglePromptImprovement,
            isEnabled: $viewModel.data.togglePromptImprovementEnabled,
            focusedField: .togglePromptImprovement,
            currentFocus: $focusedField,
            onShortcutChanged: {
              Task {
                await viewModel.saveSettings()
              }
            },
            validateShortcut: viewModel.validateShortcut
          )
          Text("Give feedback by voice to improve all system prompts (dictation, Dictate Prompt, Prompt & Read). Same as the menu bar item \"Improve from voice\".")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 12) {
            Text("Automatic system prompt improvement")
              .font(.callout)
              .fontWeight(.medium)
            Spacer(minLength: 16)
            Picker("", selection: $selectedInterval) {
              ForEach(AutoImprovementInterval.allCases, id: \.self) { interval in
                Text(interval.displayName).tag(interval)
              }
            }
            .pickerStyle(.menu)
            .frame(width: 160, alignment: .trailing)
            .onChange(of: selectedInterval) { newValue in
              UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays)
              let enabled = newValue != .never
              UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.userContextLoggingEnabled)
              DebugLogger.log("AUTO-IMPROVEMENT: Interval changed to \(newValue.displayName), logging = \(enabled)")
            }
          }

          Text("Minimum cooldown between improvement runs (from the second run onwards). Set to \"Always\" for no cooldown.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 12) {
            Text("Improve from usage")
              .font(.callout)
              .fontWeight(.medium)
            Spacer(minLength: 16)
            Button(action: {
              guard !isImprovementRunning else { return }
              isImprovementRunning = true
              Task {
                await AutoPromptImprovementScheduler.shared.runImprovementNow()
                await MainActor.run { isImprovementRunning = false }
              }
            }) {
              Label(isImprovementRunning ? "Running…" : "Improve from usage", systemImage: "sparkles")
                .font(.callout)
            }
            .buttonStyle(.bordered)
            .disabled(isImprovementRunning)
            .help("Improve prompts and context from your usage; ignores cooldown")
          }

          Text("Runs in the background using your interaction logs. You can switch to another tab; you'll be notified when it's done. Ignores cooldown.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 12) {
            Text("Improve from my voice")
              .font(.callout)
              .fontWeight(.medium)
            Spacer(minLength: 16)
            Button(action: {
              NotificationCenter.default.post(name: .startPromptImprovementRecording, object: nil)
            }) {
              Label("Start recording", systemImage: "mic.fill")
                .font(.callout)
            }
            .buttonStyle(.bordered)
            .help("Start recording to improve prompts and user context by voice (same as the Improve from voice shortcut)")
          }

          Text("Copies the current selection to the clipboard, then records your voice. Say how you want dictation, prompts, or your profile to change (e.g. \"always add bullet points\", \"I work in legal\"). Uses the same shortcut as in the menu bar.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        PromptModelSelectionView(
          title: "Model for Smart Improvement",
          subtitle: "Used for automatic Smart Improvement (suggested prompts).",
          showSectionHeader: false,
          selectedModel: Binding(
            get: { viewModel.data.selectedImprovementModel },
            set: { newValue in
              var d = viewModel.data
              d.selectedImprovementModel = newValue
              viewModel.data = d
            }
          ),
          onModelChanged: {
            UserDefaults.standard.set(
              viewModel.data.selectedImprovementModel.rawValue,
              forKey: UserDefaultsKeys.selectedImprovementModel)
            Task {
              await viewModel.saveSettings()
            }
          }
        )
      }
    }
    .onAppear {
      isImprovementRunning = AutoPromptImprovementScheduler.shared.isRunning
      let rawValue = UserDefaults.standard.integer(forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays)
      selectedInterval = AutoImprovementInterval(rawValue: rawValue) ?? .default
      let enabled = selectedInterval != .never
      UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.userContextLoggingEnabled)
      let content = SystemPromptsStore.shared.loadFullContent()
      systemPromptsText = content
      lastSavedSystemPromptsText = content
    }
    .onReceive(NotificationCenter.default.publisher(for: .userContextFileDidUpdate)) { _ in
      let content = SystemPromptsStore.shared.loadFullContent()
      systemPromptsText = content
      lastSavedSystemPromptsText = content
    }
  }

  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 How to Use",
        subtitle: "Improve from voice and automatic improvement"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("Improve from voice (shortcut):")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
          .padding(.top, 4)
        Text("1. Optionally select text (e.g. a sample you want the assistant to learn from)")
          .textSelection(.enabled)
        Text("2. Press your configured Improve from voice shortcut")
          .textSelection(.enabled)
        Text("3. Say how you want dictation, prompts, or your profile to change (e.g. \"always add bullet points\", \"I work in legal\")")
          .textSelection(.enabled)
        Text("4. Press the shortcut again to stop")
          .textSelection(.enabled)
        Text("5. The app updates system prompts; edit the System prompts section above to review or revert")
          .textSelection(.enabled)

        Text("Automatic improvement:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
          .padding(.top, 4)
        Text("Runs in the background when the cooldown has passed (after a dictation). Use \"Improve from usage\" to trigger once immediately.")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }
}
