import SwiftUI

/// Read Aloud Settings Tab - Shortcut and Voice Selection
struct ReadAloudSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Shortcuts Section
      shortcutsSection

      SpacedSectionDivider()

      // TTS Model Selection Section
      ttsModelSelectionSection
      
      SpacedSectionDivider()

      // Read Aloud Voice Selection Section
      readAloudVoiceSection
      
      SpacedSectionDivider()

      // Speech Speed Section
      speechSpeedSection
      
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
        subtitle: "Configure shortcut for reading selected text aloud"
      )

      ShortcutInputRow(
        label: "Read Aloud:",
        placeholder: "e.g., command+4",
        text: $viewModel.data.readAloud,
        isEnabled: $viewModel.data.readAloudEnabled,
        focusedField: .toggleReadAloud,
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
          "command • option • control • shift • a-z • 0-9 • f1-f12 • escape • space • up • down • left • right • comma • period"
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)
    }
  }

  // MARK: - TTS Model Selection Section
  @ViewBuilder
  private var ttsModelSelectionSection: some View {
    TTSModelSelectionView(
      selectedTTSModel: $viewModel.data.selectedTTSModel,
      onModelChanged: {
        UserDefaults.standard.set(
          viewModel.data.selectedTTSModel.rawValue,
          forKey: UserDefaultsKeys.selectedTTSModel)
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Read Aloud Voice Selection Section
  @ViewBuilder
  private var readAloudVoiceSection: some View {
    ReadAloudVoiceSelectionView(
      selectedVoice: $viewModel.data.selectedReadAloudVoice,
      onVoiceChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Speech Speed Section
  @ViewBuilder
  private var speechSpeedSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Speed",
        subtitle: "Playback speed for read aloud (1.0 = normal, higher = faster)"
      )

      HStack(spacing: 12) {
        Slider(
          value: $viewModel.data.readAloudPlaybackRate,
          in: SettingsDefaults.readAloudPlaybackRateMin...SettingsDefaults.readAloudPlaybackRateMax,
          step: 0.05
        )
        .onChange(of: viewModel.data.readAloudPlaybackRate) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }
        Text(String(format: "%.1f×", viewModel.data.readAloudPlaybackRate))
          .font(.callout)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
          .frame(minWidth: 36, alignment: .trailing)
      }
    }
  }
  
  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 How to Use",
        subtitle: "Step-by-step instructions for using read aloud mode"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Select text in any application")
          .textSelection(.enabled)
        Text("2. Press your configured shortcut")
          .textSelection(.enabled)
        Text("3. Selected text is read aloud automatically")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }
}

