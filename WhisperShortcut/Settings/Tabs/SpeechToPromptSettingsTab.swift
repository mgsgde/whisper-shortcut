import SwiftUI

/// Speech to Prompt Settings Tab - Shortcuts, Prompt, GPT Model
struct SpeechToPromptSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Shortcuts Section
      shortcutsSection
      
      // Section Divider with spacing
      sectionDivider
      
      // Model Selection Section
      modelSection
      
      // Section Divider with spacing
      sectionDivider
      
      // System Prompt Section
      promptSection
      
      // Section Divider with spacing
      sectionDivider
      
      // Usage Instructions Section
      usageInstructionsSection
    }
  }

  // MARK: - Shortcuts Section
  @ViewBuilder
  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcut",
        subtitle: "Configure shortcut for toggle prompting mode"
      )

      ShortcutInputRow(
        label: "Toggle Prompting:",
        placeholder: "e.g., command+2",
        text: $viewModel.data.togglePrompting,
        isEnabled: $viewModel.data.togglePromptingEnabled,
        focusedField: .togglePrompting,
        currentFocus: $focusedField,
        onShortcutChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        validateShortcut: viewModel.validateShortcut
      )

      // Available Keys Information
      VStack(alignment: .leading, spacing: 8) {
        Text("Available keys:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Text(
          "command • option • control • shift • a-z • 0-9 • f1-f12 • escape • up • down • left • right • comma • period"
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)
    }
  }
  
  // MARK: - Section Divider Helper
  @ViewBuilder
  private var sectionDivider: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: SettingsConstants.sectionSpacing)
      SectionDivider()
      Spacer()
        .frame(height: SettingsConstants.sectionSpacing)
    }
  }

  // MARK: - Model Selection Section
  @ViewBuilder
  private var modelSection: some View {
    PromptModelSelectionView(
      title: "🧠 Model Selection",
      selectedModel: $viewModel.data.selectedPromptModel,
      onModelChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - System Prompt Section
  @ViewBuilder
  private var promptSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      PromptTextEditor(
        title: "🤖 System Prompt",
        subtitle:
          "Additional instructions that will be combined with the base system prompt. The base prompt ensures concise responses without intros or meta text.",
        helpText:
          "Additional instructions that will be combined with the base system prompt. The base prompt ensures concise responses without intros or meta text.",
        defaultValue: AppConstants.defaultPromptModeSystemPrompt,
        text: $viewModel.data.promptModeSystemPrompt,
        focusedField: .promptModeSystemPrompt,
        currentFocus: $focusedField,
        onTextChanged: {
          Task {
            await viewModel.saveSettings()
          }
        }
      )
    }
  }
  
  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 How to Use",
        subtitle: "Step-by-step instructions for using dictate prompt mode"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Select text")
          .textSelection(.enabled)
        Text("2. Press your configured shortcut")
          .textSelection(.enabled)
        Text("3. Dictate your prompt instruction")
          .textSelection(.enabled)
        Text("4. Press the shortcut again to stop")
          .textSelection(.enabled)
        Text("5. Modified text is automatically copied to clipboard")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }

}
