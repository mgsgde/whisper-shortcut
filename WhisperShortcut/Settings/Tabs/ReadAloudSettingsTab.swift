import SwiftUI

/// Read Aloud Settings Tab — keyboard shortcut, smart-rewrite toggle, and rewrite prompt editor.
struct ReadAloudSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      keyboardShortcutSection

      SpacedSectionDivider()

      modelSection

      SpacedSectionDivider()

      voiceSection

      SpacedSectionDivider()

      playbackSpeedSection

      SpacedSectionDivider()

      smartRewriteSection

      SpacedSectionDivider()

      SystemPromptSectionEditor(
        title: "Rewrite prompt",
        subtitle: "Instructions sent to Gemini when Smart Rewriting is enabled. The model receives the selected text and returns a speech-friendly version.",
        section: .readAloudRewrite,
        defaultContent: AppConstants.defaultReadAloudRewritePrompt
      )

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
        subtitle: "Select text, then press the shortcut to have it read aloud"
      )

      ShortcutRecorderRow(
        label: "Read Aloud:",
        shortcut: $viewModel.data.readAloud,
        focusedField: .readAloudShortcut,
        currentFocus: $focusedField,
        onChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        findConflict: viewModel.findShortcutConflict,
        clearShortcut: viewModel.clearShortcut
      )
    }
  }

  // MARK: - Voice Model Section
  @ViewBuilder
  private var modelSection: some View {
    TTSModelSelectionView(
      selectedModel: $viewModel.data.selectedReadAloudModel,
      onModelChanged: {
        UserDefaults.standard.set(
          viewModel.data.selectedReadAloudModel.rawValue,
          forKey: UserDefaultsKeys.selectedReadAloudModel)
        Task { await viewModel.saveSettings() }
      }
    )
  }

  // MARK: - Voice Section
  /// Voice picker for the currently-selected provider. The catalogue and stored selection both
  /// switch with the provider, so each provider keeps its own chosen voice.
  @ViewBuilder
  private var voiceSection: some View {
    let model = viewModel.data.selectedReadAloudModel
    let provider = model.provider
    let voices = model.availableVoices
    let voiceSelection = Binding<String>(
      get: {
        let stored = viewModel.data.readAloudVoice(for: provider)
        // Show the provider default when nothing is stored or the stored id is no longer offered.
        return voices.contains(where: { $0.id == stored }) ? stored : model.defaultVoice
      },
      set: { newValue in
        viewModel.data.setReadAloudVoice(newValue, for: provider)
        UserDefaults.standard.set(newValue, forKey: provider.voiceUserDefaultsKey)
        Task { await viewModel.saveSettings() }
      }
    )

    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🎙️ Voice",
        subtitle: "The specific voice \(provider.displayName) uses. Each provider has its own set."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Voice:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: voiceSelection) {
          ForEach(voices) { voice in
            Text(voice.displayName).tag(voice.id)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 320)

        Spacer()
      }
    }
  }

  // MARK: - Playback Speed Section
  @ViewBuilder
  private var playbackSpeedSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⏩ Playback Speed",
        subtitle: "How fast the audio is played back. Pitch is preserved."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Speed:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.readAloudSpeed) {
          ForEach(ReadAloudSpeed.allCases, id: \.rawValue) { speed in
            HStack {
              Text(speed.displayName)
              if speed.isRecommended {
                Text("(Recommended)")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
            .tag(speed)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.readAloudSpeed) { _ in
          Task { await viewModel.saveSettings() }
        }

        Spacer()
      }
    }
  }

  // MARK: - Smart Rewrite Section
  @ViewBuilder
  private var smartRewriteSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🧠 Smart Rewriting",
        subtitle: "Let Gemini decide whether the selection should be read verbatim or rewritten for natural speech"
      )

      Toggle(isOn: $viewModel.data.readAloudSmartRewriteEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Rewrite text for speech before reading aloud")
            .font(.callout)
          Text("When on, code, markdown, tables and other non-prose content are summarized into a speakable form. Plain prose is passed through unchanged. Adds one short Gemini call before TTS.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.readAloudSmartRewriteEnabled) { _ in
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
        subtitle: "Read selected text aloud anywhere on your Mac"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("Highlight any text with the mouse or keyboard, then press the Read Aloud shortcut.")
          .textSelection(.enabled)
        Text("Press the shortcut again to stop playback.")
          .textSelection(.enabled)
        Text("Requires an API key for the selected voice model's provider (Settings → General). Gemini also works via sign in with Google.")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }
}
