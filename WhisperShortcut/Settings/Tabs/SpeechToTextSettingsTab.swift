import SwiftUI

/// Speech to Text Settings Tab - Shortcuts, Prompt, Transcription Model
struct SpeechToTextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var languageValidationError: String?

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

      // Difficult Words Section
      difficultWordsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Language Section
      languageSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Transcription Model Section
      modelSection
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
        "Describe domain terms for better transcription quality. Leave empty to use OpenAI's default.",
      helpText:
        "Enter domain-specific terms, jargon, or context that will help improve transcription accuracy for your specific use case.",
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
        subtitle: "ISO-639-1 code (e.g., 'en', 'de', 'fr'). Leave empty for auto-detection."
      )

      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 16) {
          Text("Language Code:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: SettingsConstants.labelWidth, alignment: .leading)
            .textSelection(.enabled)

          TextField("Auto-Detect (leave empty)", text: $viewModel.data.transcriptionLanguage)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: SettingsConstants.textFieldHeight)
            .frame(maxWidth: 300)
            .focused($focusedField, equals: .transcriptionLanguage)
            .autocorrectionDisabled()
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(languageValidationError != nil ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1)
                .padding(0)
            )
            .onChange(of: viewModel.data.transcriptionLanguage) { _, newValue in
              // Validate in real-time
              languageValidationError = viewModel.validateLanguageCode(newValue)
              
              // Only save if validation passes
              if languageValidationError == nil {
                Task {
                  await viewModel.saveSettings()
                }
              }
            }

          Spacer()
        }

        // Show validation error
        if let error = languageValidationError {
          Text(error)
            .font(.callout)
            .foregroundColor(.red)
            .textSelection(.enabled)
        }

        // Help text
        Text("Enter a 2-letter ISO-639-1 language code (e.g., 'en' for English, 'de' for German, 'fr' for French). Leave empty to let OpenAI automatically detect the language.")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
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
