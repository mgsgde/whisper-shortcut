import SwiftUI

/// Read Aloud Settings Tab — model, voice, smart rewriting. The shortcut is set in General.
struct ReadAloudSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  @State private var showResetVoiceConfirmation = false
  @State private var showingPersonaEditor = false
  /// Bumped whenever the frozen voice or the custom-persona list changes, so the reset button
  /// and the picker re-render — disk state alone does not trigger SwiftUI.
  @State private var voiceCacheGeneration = 0

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
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      TTSModelSelectionView(
        selectedModel: $viewModel.data.selectedReadAloudModel,
        onModelChanged: {
          Task { await viewModel.saveSettings() }
        }
      )

      // The Qwen3 voice models are multi-gigabyte downloads, so they get their own row here
      // rather than being fetched silently on the first Read Aloud — a menu-bar app must not
      // start a multi-gigabyte download because someone pressed a shortcut.
      if let qwen3Type = viewModel.data.selectedReadAloudModel.qwen3ModelType,
        Qwen3ModelType.isSupportedOnThisMac
      {
        ModelDownloadRow(
          store: Qwen3ModelManager.shared,
          model: qwen3Type,
          downloadedMessage: String(
            localized: "\(qwen3Type.displayName) was successfully downloaded. The first Read Aloud may take a moment to initialize the model; subsequent ones will be faster."),
          onError: { viewModel.showError($0) }
        ) {
          Text("German voices")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }
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

      // Only the Qwen3 VoiceDesign checkpoint has a freezable voice: its speaker is sampled
      // from a description, so the frozen reference is what makes a persona stable. Cloud voices
      // are fixed catalogues — nothing to manage.
      if model.qwen3ModelType == .voiceDesign {
        qwen3VoiceManagement
      }
    }
  }

  // MARK: - Qwen3 Voice Management
  /// Reset for the selected persona's frozen voice, plus the user's own personas. Kept to two
  /// plain-language controls: a "new voice" button whose whole effect is one sentence of
  /// explanation, and an editor behind one "manage" toggle. No technical terms on the surface.
  @ViewBuilder
  private var qwen3VoiceManagement: some View {
    // Reads the generation counter so a reset re-renders this whole block.
    let _ = voiceCacheGeneration
    let persona = Qwen3VoicePersona.persona(for: voiceSelectionOfQwen3Persona)
    let hasFrozenVoice = Qwen3VoiceReferenceStore.hasReference(for: persona.id)

    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      // One row per control, the explanatory caption spanning the full width below both —
      // the caption's length must not push the buttons out of alignment.
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .center, spacing: 16) {
          Button {
            showResetVoiceConfirmation = true
          } label: {
            Label(
              hasFrozenVoice ? "New voice" : "No voice saved yet",
              systemImage: hasFrozenVoice ? "arrow.triangle.2.circlepath" : "waveform.slash"
            )
          }
          .disabled(!hasFrozenVoice)

          Divider()
            .frame(height: 14)

          Button {
            showingPersonaEditor = true
          } label: {
            Label("My own voices…", systemImage: "person.crop.square.badge.plus")
          }
        }
        .padding(.leading, SettingsConstants.labelWidth + 16)

        Text(
          hasFrozenVoice
            ? "The saved voice is discarded; the next Read Aloud creates a new one."
            : "The voice is created automatically on the first Read Aloud with this persona."
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.leading, SettingsConstants.labelWidth + 16)
      }
    }
    .confirmationDialog(
      "Draw a new voice for \"\(persona.summary)\"?",
      isPresented: $showResetVoiceConfirmation,
      titleVisibility: .visible
    ) {
      Button("New voice", role: .destructive) {
        Qwen3VoiceReferenceStore.removeReference(for: persona.id)
        voiceCacheGeneration += 1
      }
    } message: {
      Text("The current voice is discarded. The next Read Aloud with this persona creates and saves a new one.")
    }
    .sheet(isPresented: $showingPersonaEditor, onDismiss: {
      // The editor can add, edit or delete personas — refresh the picker and the reset row.
      voiceCacheGeneration += 1
    }) {
      Qwen3PersonaEditorView()
    }
  }

  /// The persona id the picker currently shows, regardless of which catalogue it came from.
  private var voiceSelectionOfQwen3Persona: String {
    let model = viewModel.data.selectedReadAloudModel
    let provider = model.provider
    let stored = viewModel.data.readAloudVoice(for: provider)
    let voices = model.availableVoices
    return voices.contains(where: { $0.id == stored }) ? stored : model.defaultVoice
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
