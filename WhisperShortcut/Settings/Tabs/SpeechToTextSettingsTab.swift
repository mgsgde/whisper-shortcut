import SwiftUI

/// Speech to Text Settings Tab - Shortcuts, Prompt, Transcription Model
struct SpeechToTextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Shortcuts Section
      shortcutsSection

      // Section Divider with spacing
      sectionDivider

      // Transcription Model Section
      modelSection

      // Section Divider with spacing
      sectionDivider

      // Conditional sections based on model type
      if viewModel.data.selectedTranscriptionModel.isGemini {
        // Prompt Section (only for Gemini)
        promptSection
        
        // Section Divider with spacing
        sectionDivider
        
        // Difficult Words Section (only for Gemini)
        difficultWordsSection
        
        // Section Divider with spacing
        sectionDivider
      } else {
        // Language Section (only for Whisper)
        languageSection
        
        // Section Divider with spacing
        sectionDivider
      }
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

  // MARK: - Shortcuts Section
  @ViewBuilder
  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Toggle Shortcut",
        subtitle: "Start/Stop Dictation with one shortcut"
      )

      ShortcutInputRow(
        label: "Toggle Dictation:",
        placeholder: "e.g., command+e",
        text: $viewModel.data.toggleDictation,
        isEnabled: $viewModel.data.toggleDictationEnabled,
        focusedField: .toggleDictation,
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
      title: "💬 Prompt",
      subtitle:
        "Describe domain terms for better transcription quality. Only used for Gemini models (not Whisper). Leave empty to use Gemini's default.",
      helpText:
        "Enter domain-specific terms, jargon, or context that will help improve transcription accuracy for your specific use case. Note: This prompt is only applied when using Gemini models. Whisper models (offline) do not support custom prompts.",
      defaultValue: AppConstants.defaultTranscriptionSystemPrompt,
      text: $viewModel.data.customPromptText,
      focusedField: .customPrompt,
      currentFocus: $focusedField,
      onTextChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Difficult Words Section
  @ViewBuilder
  private var difficultWordsSection: some View {
    PromptTextEditor(
      title: "🔤 Difficult Words",
      subtitle: "One word per line. Words that are difficult to transcribe correctly.",
      helpText: "Enter one word per line. Empty lines will be ignored.",
      defaultValue: "",
      text: $viewModel.data.dictationDifficultWords,
      focusedField: .dictationDifficultWords,
      currentFocus: $focusedField,
      onTextChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Language Section
  @ViewBuilder
  private var languageSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🌐 Language",
        subtitle: "Specify the language for Whisper transcription. Auto-detect lets Whisper determine the language automatically."
      )

      Picker("Language", selection: $viewModel.data.whisperLanguage) {
        ForEach(WhisperLanguage.allCases, id: \.self) { language in
          Text(language.displayName)
            .tag(language)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onChange(of: viewModel.data.whisperLanguage) {
        Task {
          await viewModel.saveSettings()
        }
      }

      if viewModel.data.whisperLanguage.isRecommended {
        HStack {
          Image(systemName: "star.fill")
            .foregroundColor(.yellow)
            .font(.caption)
          Text("Recommended")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
        }
      }
    }
  }

  // MARK: - Model Section
  @ViewBuilder
  private var modelSection: some View {
    ModelSelectionView(
      title: "🎤 Transcription Model",
      selectedTranscriptionModel: $viewModel.data.selectedTranscriptionModel,
      onModelChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
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
