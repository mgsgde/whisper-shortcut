import SwiftUI

/// Speech to Prompt with Voice Response Settings Tab - Shortcuts, Prompt, Model, Playback Speed
struct SpeechToPromptWithVoiceResponseSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  
  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.spacing) {
      // Shortcuts Section
      shortcutsSection
      
      // Prompt Section  
      promptSection
      
      // Model Selection Section
      modelSection
      
      // Playback Speed Section
      playbackSpeedSection
      
      // Usage Instructions
      usageInstructionsSection
    }
  }
  
  // MARK: - Shortcuts Section
  @ViewBuilder
  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.sectionSpacing) {
      SectionHeader(
        title: "Shortcuts",
        subtitle: "Record prompt and receive spoken response (uses OpenAI TTS)"
      )

      ShortcutInputRow(
        label: "Start Voice Response:",
        placeholder: "e.g., command+shift+k",
        text: $viewModel.data.startVoiceResponse,
        isEnabled: $viewModel.data.startVoiceResponseEnabled,
        focusedField: .startVoiceResponse,
        currentFocus: $focusedField
      )

      ShortcutInputRow(
        label: "Stop Voice Response:",
        placeholder: "e.g., command+v",
        text: $viewModel.data.stopVoiceResponse,
        isEnabled: $viewModel.data.stopVoiceResponseEnabled,
        focusedField: .stopVoiceResponse,
        currentFocus: $focusedField
      )
      
      // ChatGPT Quick Access
      ShortcutInputRow(
        label: "Open ChatGPT:",
        placeholder: "e.g., command+1",
        text: $viewModel.data.openChatGPT,
        isEnabled: $viewModel.data.openChatGPTEnabled,
        focusedField: .openChatGPT,
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
      subtitle: "System Instructions for AI Assistant:",
      helpText: "Additional instructions that will be combined with the base system prompt. The base prompt ensures concise responses without intros or meta text.",
      defaultValue: AppConstants.defaultPromptModeSystemPrompt,
      text: $viewModel.data.promptModeSystemPrompt,
      focusedField: .promptModeSystemPrompt,
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
    VStack(alignment: .leading, spacing: 8) {
      Text("How to use Speech to Prompt with Voice Response:")
        .font(.callout)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)
        .textSelection(.enabled)

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Copy any text to clipboard (⌘C)")
          .textSelection(.enabled)
        Text("2. Dictate your prompt (e.g., ⌘⇧K)")
          .textSelection(.enabled)
        Text("3. AI processes your voice and clipboard text")
          .textSelection(.enabled)
        Text("4. Response is automatically spoken aloud")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)

      Text(
        "🔊 Voice responses use OpenAI's text-to-speech service with natural-sounding voices. You can adjust playback speed above."
      )
      .font(.callout)
      .foregroundColor(.blue)
      .padding(.top, 4)
      .textSelection(.enabled)
    }
    .padding(12)
    .background(Color(.controlBackgroundColor).opacity(0.5))
    .cornerRadius(SettingsConstants.cornerRadius)
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .stroke(Color(.separatorColor), lineWidth: 1)
    )
  }
}

#if DEBUG
struct SpeechToPromptWithVoiceResponseSettingsTab_Previews: PreviewProvider {
  static var previews: some View {
    @FocusState var focusedField: SettingsFocusField?
    
    SpeechToPromptWithVoiceResponseSettingsTab(viewModel: SettingsViewModel(), focusedField: $focusedField)
      .padding()
      .frame(width: 600, height: 1000)
  }
}
#endif
