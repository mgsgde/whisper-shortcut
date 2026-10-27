import SwiftUI

/// Read Aloud Settings Tab — model, voice, smart rewriting. The shortcut is set in General.
struct ReadAloudSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      modelSection

      SpacedSectionDivider()

      voiceSection

      SpacedSectionDivider()

      playbackSpeedSection

      SpacedSectionDivider()

      smartRewriteSection

      SpacedSectionDivider()

      SystemPromptSectionEditor(
        title: "Rewrite Prompt",
        systemImage: "text.badge.star",
        subtitle: "Instructions sent to your chat model when Smart Rewriting is enabled. It receives the selected text and returns a speech-friendly version.",
        section: .readAloudRewrite,
        defaultContent: AppConstants.defaultReadAloudRewritePrompt
      )

      SpacedSectionDivider()

      usageSection
    }
  }

  // MARK: - Voice Model Section
  @ViewBuilder
  private var modelSection: some View {
    TTSModelSelectionView(
      selectedModel: $viewModel.data.selectedReadAloudModel,
      onModelChanged: {
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
        title: "Voice",
        systemImage: "mic",
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
        .accessibilityLabel("Voice")

        Spacer()
      }
    }
  }

  // MARK: - Playback Speed Section
  @ViewBuilder
  private var playbackSpeedSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Playback Speed",
        systemImage: "gauge.with.dots.needle.67percent",
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
        title: "Smart Rewriting",
        systemImage: "wand.and.stars",
        subtitle: "Let your chat model (Settings → Chat) rewrite code, logs, Markdown or messy notes for natural speech. Plain prose is read as is, without the extra round trip."
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
        title: "How to Use",
        systemImage: "questionmark.circle",
        subtitle: "Read selected text aloud anywhere on your Mac"
      )

      // Selection-based Read Aloud copies via ⌘C (Accessibility); no shortcut in the App Store build.
      #if !APP_STORE
      ShortcutHintRow(label: "Shortcut:", shortcut: viewModel.data.readAloud)
      #endif

      VStack(alignment: .leading, spacing: 8) {
        Text("Highlight any text with the mouse or keyboard, then press the Read Aloud shortcut.")
          .textSelection(.enabled)
        Text("Press the shortcut again to stop playback.")
          .textSelection(.enabled)
        Text("Requires an API key for cloud voice models (Settings → Accounts). The on-device macOS voice needs none, and is selected automatically in Offline Mode. Gemini also works via sign in with Google.")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }
}
