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
