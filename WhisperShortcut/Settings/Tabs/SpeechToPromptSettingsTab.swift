import SwiftUI

/// Speech to Prompt Settings Tab - Shortcuts, Prompt, GPT Model
struct SpeechToPromptSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Shortcuts Section
      shortcutsSection
      
      SpacedSectionDivider()

      // Model Selection Section
      modelSection
      
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
        subtitle: "Configure shortcut for toggle prompting mode"
      )

      ShortcutInputRow(
        label: "Toggle Prompting:",
        placeholder: ShortcutConfig.examplePlaceholder(for: ShortcutConfig.default.startPrompting),
        text: $viewModel.data.togglePrompting,
        isEnabled: $viewModel.data.togglePromptingEnabled,
        focusedField: .togglePrompting,
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
  
  // MARK: - Model Selection Section
  @ViewBuilder
  private var modelSection: some View {
    PromptModelSelectionView(
      title: "🧠 Model Selection",
      selectedModel: $viewModel.data.selectedPromptModel,
      onModelChanged: {
        UserDefaults.standard.set(
          viewModel.data.selectedPromptModel.rawValue,
          forKey: UserDefaultsKeys.selectedPromptModel)
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
        subtitle: "Step-by-step instructions for using dictate prompt mode"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Select text")
          .textSelection(.enabled)
        Text("2. Press your configured shortcut")
          .textSelection(.enabled)
        Text("3. Dictate your prompt instruction")
          .textSelection(.enabled)
        Text("4. Press the shortcut again to stop")
          .textSelection(.enabled)
        Text("5. Modified text is automatically copied to clipboard")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }

}
