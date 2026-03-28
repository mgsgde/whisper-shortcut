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

      readAloudSection

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
        subtitle: "Open the Gemini chat window"
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
      subscriptionMode: !KeychainManager.shared.hasValidGoogleAPIKey() && DefaultGoogleAuthService.shared.isSignedIn(),
      subscriptionFixedModelDescription: "The Open Gemini window uses \(SubscriptionModelsConfigService.effectiveOpenGeminiModel().displayName) (fixed).",
      subscriptionEffectiveModel: SubscriptionModelsConfigService.effectiveOpenGeminiModel(),
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

  // MARK: - Read Aloud Section
  @ViewBuilder
  private var readAloudSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Read Aloud",
        subtitle: "Voice and model for the Read Aloud button in the Gemini chat window"
      )

      TTSModelSelectionView(
        selectedTTSModel: Binding(
          get: { viewModel.data.selectedTTSModel },
          set: { newValue in
            var d = viewModel.data
            d.selectedTTSModel = newValue
            viewModel.data = d
          }
        ),
        onModelChanged: {
          Task { await viewModel.saveSettings() }
        }
      )

      ReadAloudVoiceSelectionView(
        selectedVoice: Binding(
          get: { viewModel.data.selectedReadAloudVoice },
          set: { newValue in
            var d = viewModel.data
            d.selectedReadAloudVoice = newValue
            viewModel.data = d
          }
        ),
        onVoiceChanged: {
          Task { await viewModel.saveSettings() }
        }
      )

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Playback speed: \(String(format: "%.1f", viewModel.data.readAloudPlaybackRate))x")
            .font(.callout)
          Spacer()
        }
        Slider(
          value: Binding(
            get: { viewModel.data.readAloudPlaybackRate },
            set: { newValue in
              var d = viewModel.data
              d.readAloudPlaybackRate = newValue
              viewModel.data = d
            }
          ),
          in: SettingsDefaults.readAloudPlaybackRateMin...SettingsDefaults.readAloudPlaybackRateMax,
          step: 0.1
        )
        .onChange(of: viewModel.data.readAloudPlaybackRate) { _, _ in
          Task { await viewModel.saveSettings() }
        }
        Text("1.0x is normal speed. 1.5x–2.0x speeds up playback.")
          .font(.caption)
          .foregroundColor(.secondary)
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
