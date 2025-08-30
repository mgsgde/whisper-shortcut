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

      // Playback Speed Section
      playbackSpeedSection

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
        title: "Shortcuts",
        subtitle:
          "Dictate Prompt → AI Assistant Response with Voice Response (uses selected text as context)"
      )

      ShortcutInputRow(
        label: "Start Voice Response:",
        placeholder: "e.g., command+shift+g",
        text: $viewModel.data.startVoiceResponse,
        isEnabled: $viewModel.data.startVoiceResponseEnabled,
        focusedField: .startVoiceResponse,
        currentFocus: $focusedField
      )

      ShortcutInputRow(
        label: "Stop Voice Response:",
        placeholder: "e.g., command+g",
        text: $viewModel.data.stopVoiceResponse,
        isEnabled: $viewModel.data.stopVoiceResponseEnabled,
        focusedField: .stopVoiceResponse,
        currentFocus: $focusedField
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
      title: "AI Assistant System Prompt",
      subtitle:
        "Instructions for the AI assistant that will generate responses to be spoken aloud. Optimize for clear, natural speech.",
      helpText:
        "Instructions for the AI assistant that will generate responses to be spoken aloud. Optimize for clear, natural speech.",
      defaultValue: AppConstants.defaultVoiceResponseSystemPrompt,
      text: $viewModel.data.voiceResponseSystemPrompt,
      focusedField: .voiceResponseSystemPrompt,
      currentFocus: $focusedField
    )
  }

  // MARK: - Model Section
  @ViewBuilder
  private var modelSection: some View {
    GPTModelSelectionView(
      title: "GPT Model",
      selectedModel: $viewModel.data.selectedVoiceResponseGPTModel
    )
  }

  // MARK: - Playback Speed Section
  @ViewBuilder
  private var playbackSpeedSection: some View {
    PlaybackSpeedControl(playbackSpeed: $viewModel.data.audioPlaybackSpeed)
  }

  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "How to use Speech to Prompt with Voice Response",
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
      .frame(width: 600, height: 1000)
    }
  }
#endif
