import SwiftUI

/// Prompt and Read Settings Tab - Shortcut, Model Selection, System Prompt, Voice Selection
struct PromptAndReadSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Shortcuts Section
      shortcutsSection

      SpacedSectionDivider()

      // Model Section
      modelSection

      SpacedSectionDivider()

      // Read Aloud Voice Selection Section
      readAloudVoiceSection

      SpacedSectionDivider()

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
        subtitle: "Configure shortcut for prompt read mode"
      )

      ShortcutInputRow(
        label: "Prompt Read Mode:",
        placeholder: ShortcutConfig.examplePlaceholder(for: ShortcutConfig.default.readSelectedText),
        text: $viewModel.data.readSelectedText,
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
          ShortcutConfig.availableKeysHint
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)
    }
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
          UserDefaults.standard.set(
            viewModel.data.selectedPromptAndReadModel.rawValue,
            forKey: UserDefaultsKeys.selectedPromptAndReadModel)
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
        subtitle: "Step-by-step instructions for using prompt read mode"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Select text")
          .textSelection(.enabled)
        Text("2. Speak your prompt")
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

