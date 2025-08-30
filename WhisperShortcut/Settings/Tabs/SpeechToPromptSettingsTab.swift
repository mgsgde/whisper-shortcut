import SwiftUI

/// Speech to Prompt Settings Tab - Shortcuts, Prompt, GPT Model
struct SpeechToPromptSettingsTab: View {
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
        subtitle: "Dictate Prompt → AI Assistant Response (uses clipboard as context)"
      )

      ShortcutInputRow(
        label: "Start Prompting:",
        placeholder: "e.g., command+shift+j",
        text: $viewModel.data.startPrompting,
        isEnabled: $viewModel.data.startPromptingEnabled,
        focusedField: .startPrompting,
        currentFocus: $focusedField
      )

      ShortcutInputRow(
        label: "Stop Prompting:",
        placeholder: "e.g., command+p",
        text: $viewModel.data.stopPrompting,
        isEnabled: $viewModel.data.stopPromptingEnabled,
        focusedField: .stopPrompting,
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
      selectedModel: $viewModel.data.selectedGPTModel
    )
  }
  
  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("How to use Speech to Prompt:")
        .font(.callout)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)
        .textSelection(.enabled)

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Copy any text to clipboard (⌘C)")
          .textSelection(.enabled)
        Text("2. Dictate your prompt (e.g., ⌘⇧J)")
          .textSelection(.enabled)
        Text("3. AI receives both your voice and clipboard text")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)

      Text(
        "💡 Auto-copy: [GitHub version](https://github.com/mgsgde/whisper-shortcut) automatically copies selected text. Mac App Store version requires manual ⌘C."
      )
      .font(.callout)
      .foregroundColor(.orange)
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
struct SpeechToPromptSettingsTab_Previews: PreviewProvider {
  static var previews: some View {
    @FocusState var focusedField: SettingsFocusField?
    
    SpeechToPromptSettingsTab(viewModel: SettingsViewModel(), focusedField: $focusedField)
      .padding()
      .frame(width: 600, height: 800)
  }
}
#endif
