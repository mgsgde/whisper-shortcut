import SwiftUI

/// Open Gemini Settings Tab - Shortcut and model for the Gemini chat window
struct OpenGeminiSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      keyboardShortcutSection

      SpacedSectionDivider()

      modelSection

      SpacedSectionDivider()

      windowBehaviorSection

      SpacedSectionDivider()

      usageSection
    }
  }

  // MARK: - Keyboard Shortcut Section
  @ViewBuilder
  private var keyboardShortcutSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcut",
        subtitle: "Open the Gemini chat window with this shortcut"
      )

      ShortcutInputRow(
        label: "Open Gemini:",
        placeholder: "e.g., command+8",
        text: $viewModel.data.openGemini,
        isEnabled: $viewModel.data.openGeminiEnabled,
        focusedField: .toggleGemini,
        currentFocus: $focusedField,
        onShortcutChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        validateShortcut: viewModel.validateShortcut
      )

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

  // MARK: - Model Section
  @ViewBuilder
  private var modelSection: some View {
    PromptModelSelectionView(
      title: "Model for Open Gemini window",
      subtitle: "Choose which Gemini model powers the chat in the Open Gemini window",
      selectedModel: $viewModel.data.selectedOpenGeminiModel,
      onModelChanged: {
        UserDefaults.standard.set(
          viewModel.data.selectedOpenGeminiModel.rawValue,
          forKey: UserDefaultsKeys.selectedOpenGeminiModel)
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Window Behavior Section
  @ViewBuilder
  private var windowBehaviorSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Window Behavior",
        subtitle: "Control how the Gemini chat window appears"
      )

      Toggle(isOn: $viewModel.data.geminiWindowFloating) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Keep Gemini window on top of other windows")
            .font(.callout)
        }
      }
      .toggleStyle(SwitchToggleStyle())
      .onChange(of: viewModel.data.geminiWindowFloating) { _, _ in
        Task {
          await viewModel.saveSettings()
          GeminiWindowManager.shared.applyWindowPreferences()
        }
      }
    }
  }

  // MARK: - Usage Section
  @ViewBuilder
  private var usageSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 How to Use",
        subtitle: "Open the Gemini chat window from the menu bar or with your shortcut"
      )

      Text("Use the shortcut or the menu bar item \"Open Gemini\" to open the Gemini chat window.")
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
    }
  }
}
