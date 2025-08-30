import SwiftUI

/// Speech to Text Settings Tab - Shortcuts, Prompt, Transcription Model
struct SpeechToTextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.spacing) {
      // Shortcuts Section
      shortcutsSection

      // Prompt Section
      promptSection

      // Transcription Model Section
      modelSection
    }
  }

  // MARK: - Shortcuts Section
  @ViewBuilder
  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.sectionSpacing) {
      SectionHeader(
        title: "Shortcuts",
        subtitle: "Dictate → Text Conversion"
      )

      ShortcutInputRow(
        label: "Start Dictation:",
        placeholder: "e.g., command+shift+e",
        text: $viewModel.data.startShortcut,
        isEnabled: $viewModel.data.startShortcutEnabled,
        focusedField: .startShortcut,
        currentFocus: $focusedField
      )

      ShortcutInputRow(
        label: "Stop Recording:",
        placeholder: "e.g., command+e",
        text: $viewModel.data.stopShortcut,
        isEnabled: $viewModel.data.stopShortcutEnabled,
        focusedField: .stopShortcut,
        currentFocus: $focusedField
      )
    }
  }

  // MARK: - Prompt Section
  @ViewBuilder
  private var promptSection: some View {
    PromptTextEditor(
      title: "Prompt",
      subtitle: "Domain Terms & Context:",
      helpText:
        "Describe domain terms for better transcription quality. Leave empty to use OpenAI's default.",
      defaultValue: TranscriptionPrompt.defaultPrompt.text,
      text: $viewModel.data.customPromptText,
      focusedField: .customPrompt,
      currentFocus: $focusedField
    )
  }

  // MARK: - Model Section
  @ViewBuilder
  private var modelSection: some View {
    ModelSelectionView(
      title: "Transcription Model",
      selectedModel: $viewModel.data.selectedModel
    )
  }
}

#if DEBUG
  struct SpeechToTextSettingsTab_Previews: PreviewProvider {
    static var previews: some View {
      @FocusState var focusedField: SettingsFocusField?

      SpeechToTextSettingsTab(viewModel: SettingsViewModel(), focusedField: $focusedField)
        .padding()
        .frame(width: 600, height: 800)
    }
  }
#endif
