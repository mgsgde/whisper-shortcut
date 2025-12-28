import SwiftUI

/// Prompt and Read Settings Tab - Shortcut, System Prompt, Model Selection, Voice Selection
struct PromptAndReadSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Shortcuts Section
      shortcutsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Prompt Section
      promptSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Model Section
      modelSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Read Aloud Voice Selection Section
      readAloudVoiceSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Usage Instructions Section
      usageInstructionsSection
    }
  }

  // MARK: - Shortcuts Section
  @ViewBuilder
  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcuts",
        subtitle: "Configure shortcut for prompt and read mode"
      )

      ShortcutInputRow(
        label: "Prompt & Read:",
        placeholder: "e.g., command+3",
        text: $viewModel.data.readSelectedText,
        isEnabled: $viewModel.data.readSelectedTextEnabled,
        focusedField: .toggleReadSelectedText,
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

  // MARK: - Prompt Section
  @ViewBuilder
  private var promptSection: some View {
    PromptTextEditor(
      title: "🤖 System Prompt",
      subtitle:
        "Additional instructions that will be combined with the base system prompt. The base prompt ensures concise responses without intros or meta text.",
      helpText:
        "Additional instructions that will be combined with the base system prompt. The base prompt ensures concise responses without intros or meta text.",
      defaultValue: AppConstants.defaultPromptAndReadSystemPrompt,
      text: $viewModel.data.promptAndReadSystemPrompt,
      focusedField: .promptAndReadSystemPrompt,
      currentFocus: $focusedField,
      onTextChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Model Section
  @ViewBuilder
  private var modelSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      // Model Selection (GPT-5 and GPT-Audio)
      PromptModelSelectionView(
        title: "🧠 Model Selection",
        selectedModel: $viewModel.data.selectedPromptAndReadModel,
        onModelChanged: {
          Task {
            await viewModel.saveSettings()
          }
        }
      )
      
      // Reasoning Effort removed - GPT-Audio models don't support reasoning
    }
  }

  // MARK: - Read Aloud Voice Selection Section
  @ViewBuilder
  private var readAloudVoiceSection: some View {
    ReadAloudVoiceSelectionView(
      selectedVoice: $viewModel.data.selectedPromptAndReadVoice,
      onVoiceChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 How to Use",
        subtitle: "Step-by-step instructions for using the prompt and read mode"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Select text")
          .textSelection(.enabled)
        Text("2. Dictate your prompt")
          .textSelection(.enabled)
        Text("3. AI receives both your voice and selected text")
          .textSelection(.enabled)
        Text("4. AI response is read aloud automatically")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }
}

#if DEBUG
  struct PromptAndReadSettingsTab_Previews: PreviewProvider {
    static var previews: some View {
      @FocusState var focusedField: SettingsFocusField?

      PromptAndReadSettingsTab(viewModel: SettingsViewModel(), focusedField: $focusedField)
        .padding()
        .frame(width: 600, height: 900)
    }
  }
#endif

