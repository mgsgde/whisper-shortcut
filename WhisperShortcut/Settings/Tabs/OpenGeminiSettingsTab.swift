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
        placeholder: ShortcutConfig.examplePlaceholder(for: ShortcutConfig.default.openGemini),
        text: $viewModel.data.openGemini,
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
        title: "🪟 Window Behavior",
        subtitle: "Control how the Gemini chat window behaves"
      )

      Toggle(isOn: $viewModel.data.geminiCloseOnFocusLoss) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Close window when losing focus")
            .font(.callout)
          Text("Automatically closes the chat window when it loses focus.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.geminiCloseOnFocusLoss) { _ in
        Task { await viewModel.saveSettings() }
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
