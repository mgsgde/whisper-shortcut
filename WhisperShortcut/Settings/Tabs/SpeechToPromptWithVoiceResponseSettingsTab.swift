import SwiftUI

/// Speech to Prompt with Voice Response Settings Tab - Shortcuts, Prompt, Model, Playback Speed
struct SpeechToPromptWithVoiceResponseSettingsTab: View {
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


      // Conversation Memory Section
      conversationMemorySection

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
        title: "⌨️ Toggle Shortcut",
        subtitle:
          "Start/Stop Voice Response with one shortcut (uses selected text as context)"
      )

      ShortcutInputRow(
        label: "Toggle Voice Response:",
        placeholder: "e.g., command+x",
        text: $viewModel.data.toggleVoiceResponse,
        isEnabled: $viewModel.data.toggleVoiceResponseEnabled,
        focusedField: .toggleVoiceResponse,
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
        "Instructions for the AI assistant that will generate responses to be spoken aloud. Optimize for clear, natural speech.",
      helpText:
        "Instructions for the AI assistant that will generate responses to be spoken aloud. Optimize for clear, natural speech.",
      defaultValue: AppConstants.defaultVoiceResponseSystemPrompt,
      text: $viewModel.data.voiceResponseSystemPrompt,
      focusedField: .voiceResponseSystemPrompt,
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
    GPTModelSelectionView(
      title: "🧠 GPT-Audio Model",
      selectedModel: $viewModel.data.selectedGPTAudioModel,
      onModelChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }


  // MARK: - Conversation Memory Section
  @ViewBuilder
  private var conversationMemorySection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🧠 Conversation Memory",
        subtitle:
          "Automatically clear conversation history after this time for voice response mode. Set to 'Never' to always continue the same conversation."
      )

      ConversationTimeoutSelectionView(
        selectedTimeout: $viewModel.data.voiceResponseConversationTimeout
      )
      .onChange(of: viewModel.data.voiceResponseConversationTimeout) { _, _ in
        Task {
          await viewModel.saveSettings()
        }
      }
    }
  }

  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 How to Use",
        subtitle: "Step-by-step instructions for using the voice response mode"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Select text")
          .textSelection(.enabled)
        Text("2. Dictate your prompt")
          .textSelection(.enabled)
        Text("3. AI processes your voice and selected text")
          .textSelection(.enabled)
        Text("4. Response is automatically spoken aloud")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }
}

#if DEBUG
  struct SpeechToPromptWithVoiceResponseSettingsTab_Previews: PreviewProvider {
    static var previews: some View {
      @FocusState var focusedField: SettingsFocusField?

      SpeechToPromptWithVoiceResponseSettingsTab(
        viewModel: SettingsViewModel(), focusedField: $focusedField
      )
      .padding()
      .frame(width: 600, height: 1100)
    }
  }
#endif
