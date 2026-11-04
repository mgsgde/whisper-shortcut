import SwiftUI

/// Read Aloud Settings Tab — model, voice, smart rewriting. The shortcut is set in General.
struct ReadAloudSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var ownServerKeyDraft = ""
  @FocusState private var ownServerKeyFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      modelSection

      SpacedSectionDivider()

      voiceSection

      SpacedSectionDivider()

      if viewModel.data.selectedReadAloudModel.provider == .custom {
        ownServerSection

        SpacedSectionDivider()
      }

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
  ///
  /// `.custom` has no in-app catalogue — the ids live on the user's server — so it gets a free-text
  /// field instead of a picker. `mlx-audio` lists them at `GET /v1/audio/voices`.
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

      if provider == .custom {
        customVoiceField
      } else {
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
  }

  /// Free-text voice id for the user's own server. Stored under the `.custom` voice key, so it
  /// survives switching to another provider and back.
  @ViewBuilder
  private var customVoiceField: some View {
    let binding = Binding<String>(
      get: {
        // Empty stays empty (the prompt shows the default); the "alloy" fallback is applied at
        // read time in `ReadAloudPreferences.voice(for:)`.
        viewModel.data.readAloudVoice(for: .custom)
      },
      set: { raw in
        let newValue = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.data.setReadAloudVoice(newValue, for: .custom)
        UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.selectedReadAloudVoiceCustom)
        Task { await viewModel.saveSettings() }
      }
    )

    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text("Voice:")
        .font(.body)
        .fontWeight(.medium)
        .frame(width: SettingsConstants.labelWidth, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        TextField(text: binding, prompt: Text(verbatim: TTSModel.ownServerTTS.defaultVoice)) {
          Text("Voice id")
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .frame(height: SettingsConstants.textFieldHeight)
        .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)

        Text("The voice id your server accepts. mlx-audio lists them at /v1/audio/voices; LiteLLM and LM Studio pass the id through to the model behind them.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: SettingsConstants.apiKeyMaxWidth, alignment: .leading)

      Spacer(minLength: 0)
    }
  }

  // MARK: - Own Server Section
  /// The shared own-server settings, shown only for the "Own server" voice model. Same URL and key
  /// as Dictate, Dictate Prompt and Chat (`CustomEndpointPreferences`) — only the TTS model id is
  /// Read Aloud's own, because a chat model cannot synthesize speech.
  @ViewBuilder
  private var ownServerSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Own server",
        systemImage: "server.rack",
        subtitle: "The same server Dictate, Dictate Prompt and Chat use. Setting the URL and key once is enough."
      )

      ownServerFieldRow("Base URL:") {
        TextField("http://localhost:8000/v1", text: ownServerURLBinding)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
      } caption: {
        Text("Up to /v1, including the port: http://localhost:8000/v1 for mlx-audio, http://localhost:1234/v1 for LM Studio, http://localhost:4000/v1 for LiteLLM.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      ownServerFieldRow("TTS model:") {
        TextField(SettingsDefaults.customTTSModelID, text: customTTSModelBinding)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
      } caption: {
        Text("The model id your server synthesizes with, e.g. mlx-community/Qwen3-TTS-12Hz-0.6B for mlx-audio.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      ownServerFieldRow("API key:") {
        SecureField("Optional", text: ownServerKeyBinding)
          .focused($ownServerKeyFocused)
          .onSubmit { commitOwnServerKey() }
          .onChange(of: ownServerKeyFocused) { _, focused in if !focused { commitOwnServerKey() } }
          .onAppear { ownServerKeyDraft = KeychainManager.shared.get(.customOpenAIChatAPIKey) ?? "" }
          .onDisappear { commitOwnServerKey() }
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
      } caption: {
        Text("Optional. A keyless server on your own machine works without one.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text("The same URL and key serve Dictate, Dictate Prompt and Chat, so setting it once is enough.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Writes straight to UserDefaults: the URL is not part of `SettingsData`, and the other tabs'
  /// `OwnServerEndpointSection` reads the same key the same way.
  private var ownServerURLBinding: Binding<String> {
    Binding(
      get: { UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL) ?? "" },
      set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.customOpenAIChatEndpointURL) })
  }

  private var customTTSModelBinding: Binding<String> {
    Binding(
      get: { UserDefaults.standard.string(forKey: UserDefaultsKeys.customTTSModelID) ?? "" },
      set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.customTTSModelID) })
  }

  /// The key lives in the Keychain, not UserDefaults. The field edits a local draft that is
  /// loaded on appear and written to the Keychain on submit, focus loss or disappear — not on
  /// every keystroke.
  private var ownServerKeyBinding: Binding<String> {
    Binding(get: { ownServerKeyDraft }, set: { ownServerKeyDraft = $0 })
  }

  private func commitOwnServerKey() {
    let trimmed = ownServerKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != (KeychainManager.shared.get(.customOpenAIChatAPIKey) ?? "") else { return }
    if !KeychainManager.shared.save(trimmed, for: .customOpenAIChatAPIKey) {
      DebugLogger.log("READ-ALOUD: Failed to save own-server API key to Keychain")
    }
  }

  private func ownServerFieldRow<Field: View, Caption: View>(
    _ label: LocalizedStringKey,
    @ViewBuilder field: () -> Field,
    @ViewBuilder caption: () -> Caption
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label)
        .font(.body)
        .fontWeight(.medium)
        .frame(width: SettingsConstants.labelWidth, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        field()
        caption()
      }
      .frame(maxWidth: SettingsConstants.apiKeyMaxWidth, alignment: .leading)

      Spacer(minLength: 0)
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
          Text("Adds one short model call before reading.")
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
        subtitle: nil
      )

      // Selection-based Read Aloud copies via ⌘C (Accessibility) in the direct build. The App
      // Store build receives the selection from a macOS Service instead.
      #if APP_STORE
      Text("In this version, select text, then right-click → Services → Read Aloud with WhisperShortcut. To give it a keyboard shortcut, open System Settings → Keyboard → Keyboard Shortcuts → Services → Text.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      #else
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
