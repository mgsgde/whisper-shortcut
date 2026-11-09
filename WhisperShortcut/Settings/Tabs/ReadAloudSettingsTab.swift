import SwiftUI

/// Read Aloud Settings Tab — model, voice, smart rewriting. The shortcut is set in General.
struct ReadAloudSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  @State private var showingPersonaEditor = false
  /// Bumped whenever the frozen voice or the custom-persona list changes, so the reset button
  /// and the picker re-render — disk state alone does not trigger SwiftUI.
  @State private var voiceCacheGeneration = 0
  /// A voice is being generated (create or preview). Disables the row so a second click cannot
  /// start a second multi-second generation against the same model.
  @State private var isGeneratingVoice = false
  /// A preview is audible right now; the Listen button turns into Stop.
  @State private var isPlayingPreview = false

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
        qwen3Type.isOfferable
      {
        ModelDownloadRow(
          store: Qwen3ModelManager.shared,
          model: qwen3Type,
          downloadedMessage: String(
            localized: "\(qwen3Type.displayName) was successfully downloaded. The first Read Aloud may take a moment to initialize the model; subsequent ones will be faster."),
          onError: { viewModel.showError($0) }
        ) {
          Text(
            qwen3Type == .customVoice
              ? String(localized: "Fastest")
              : String(localized: "German voices")
          )
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
      // from a description, so the frozen reference is what makes a persona stable. CustomVoice
      // speakers are fixed ids and cloud voices are fixed catalogues — nothing to manage.
      if model.qwen3ModelType == .voiceDesign {
        qwen3VoiceManagement
      }
    }
  }

  // MARK: - Qwen3 Voice Management
  /// Create, audition and reset the selected persona's voice, plus the user's own personas.
  ///
  /// The voice used to be created implicitly on the first Read Aloud, which meant the user could
  /// not hear it before committing to a whole text, and could not compare candidates without
  /// reading something aloud each time. Both now happen here: "Create voice" generates and stores
  /// the clip, "Listen" plays a short sample of it, "New voice" discards it so the next click draws
  /// a different one.
  @ViewBuilder
  private var qwen3VoiceManagement: some View {
    // Reads the generation counter so a reset re-renders this whole block.
    let _ = voiceCacheGeneration
    let persona = Qwen3VoicePersona.persona(for: voiceSelectionOfQwen3Persona)
    let hasFrozenVoice = Qwen3VoiceReferenceStore.hasReference(for: persona.id)
    let isUserProvided = Qwen3VoiceReferenceStore.isUserProvided(for: persona.id)
    let modelType = viewModel.data.selectedReadAloudModel.qwen3ModelType ?? .voiceDesign

    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      // One row per control, the explanatory caption spanning the full width below both —
      // the caption's length must not push the buttons out of alignment.
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .center, spacing: 16) {
          Button {
            if isPlayingPreview {
              Qwen3VoicePreviewPlayer.shared.stop()
            } else {
              previewVoice(persona: persona, modelType: modelType)
            }
          } label: {
            Label(
              isPlayingPreview ? "Stop" : "Listen",
              systemImage: isPlayingPreview ? "stop.fill" : "play.fill")
          }
          .disabled(isGeneratingVoice)

          Divider()
            .frame(height: 14)

          Button {
            createVoice(persona: persona, modelType: modelType)
          } label: {
            Label(
              isUserProvided
                ? "Replace recording"
                : (hasFrozenVoice ? "New voice" : "Create voice"),
              systemImage: isUserProvided
                ? "waveform.badge.plus"
                : (hasFrozenVoice ? "arrow.triangle.2.circlepath" : "waveform.badge.plus"))
          }
          .disabled(isGeneratingVoice)

          Divider()
            .frame(height: 14)

          Button {
            showingPersonaEditor = true
          } label: {
            Label("My own voices…", systemImage: "person.crop.square.badge.plus")
          }
          .disabled(isGeneratingVoice)

          if isGeneratingVoice {
            ProgressView()
              .controlSize(.small)
            Text("Creating the voice…")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        .padding(.leading, SettingsConstants.labelWidth + 16)

        Text(
          isUserProvided
            ? "This voice comes from your own recording. Listen plays a sample; Replace recording draws a described voice instead."
            : (hasFrozenVoice
              ? "Listen plays a short sample of the saved voice. New voice draws a different one and replaces it."
              : "Create voice draws a voice for this persona now and saves it. Listen plays a sample; New voice draws another.")
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.leading, SettingsConstants.labelWidth + 16)
      }
    }
    .sheet(isPresented: $showingPersonaEditor, onDismiss: {
      // The editor can add, edit or delete personas — refresh the picker and the reset row.
      voiceCacheGeneration += 1
    }) {
      Qwen3PersonaEditorView()
    }
    // A preview belongs to the persona that was selected when it started. Switching persona or
    // leaving the tab must not leave the previous voice talking.
    .onChange(of: voiceSelectionOfQwen3Persona) { _ in
      Qwen3VoicePreviewPlayer.shared.stop()
    }
    .onDisappear {
      Qwen3VoicePreviewPlayer.shared.stop()
    }
  }

  /// Generates and stores the persona's voice, then plays it so the user hears what they got.
  private func createVoice(persona: Qwen3VoicePersona, modelType: Qwen3ModelType) {
    guard !isGeneratingVoice else { return }
    isGeneratingVoice = true
    Qwen3VoicePreviewPlayer.shared.stop()
    Task {
      defer { isGeneratingVoice = false }
      do {
        let pcm = try await Qwen3TTSService.shared.createVoiceReference(
          for: persona, modelType: modelType)
        voiceCacheGeneration += 1
        try playPreview(pcm)
      } catch {
        viewModel.showError(error.localizedDescription)
      }
    }
  }

  /// Plays a sample of the persona's current voice. Creates the voice first when none exists, so
  /// "Listen" is never a dead end on a fresh persona.
  private func previewVoice(persona: Qwen3VoicePersona, modelType: Qwen3ModelType) {
    guard !isGeneratingVoice else { return }
    isGeneratingVoice = true
    Task {
      defer { isGeneratingVoice = false }
      do {
        let pcm = try await Qwen3TTSService.shared.previewPCM(for: persona, modelType: modelType)
        voiceCacheGeneration += 1
        try playPreview(pcm)
      } catch {
        viewModel.showError(error.localizedDescription)
      }
    }
  }

  /// Starts the sample and keeps the button in its Stop state until the clip ends on its own.
  private func playPreview(_ pcm: Data) throws {
    try Qwen3VoicePreviewPlayer.shared.play(pcm: pcm) { [self] in
      isPlayingPreview = false
    }
    isPlayingPreview = true
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
