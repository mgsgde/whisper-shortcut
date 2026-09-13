import SwiftUI

/// Speech to Text Settings Tab - Shortcuts, Prompt, Transcription Model
struct SpeechToTextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @ObservedObject var modelManager = ModelManager.shared
  /// Collapsed by default when the selected model ignores the system prompt — it is still there
  /// for the user who switches back to a cloud model, just not in the way of the field that works.
  @State private var showIgnoredSystemPrompt = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Shortcuts Section
      shortcutsSection

      SpacedSectionDivider()

      // Transcription Model Section
      modelSection

      SpacedSectionDivider()

      // Available Models Section
      offlineModelsSection

      SpacedSectionDivider()

      // Language Section (only for Whisper)
      if !viewModel.data.selectedTranscriptionModel.isGemini {
        languageSection
        SpacedSectionDivider()
      }

      // The two text editors, ordered by what the *selected* model actually reads.
      //
      // For offline Whisper and GPT Transcribe the system prompt is inert — the model's API takes
      // no instructions — while the Glossary is the only lever there is. Showing the dead editor
      // first, full size, taught users to tune a field that does nothing; a banner saying so was
      // not enough, because the layout said the opposite. So when the prompt is ignored, the
      // Glossary moves up and the prompt collapses behind a disclosure, still editable for
      // whenever a cloud model is selected again.
      if let ignoredReason = viewModel.data.selectedTranscriptionModel.systemPromptIgnoredReason {
        glossaryEditor

        SpacedSectionDivider()

        DisclosureGroup(isExpanded: $showIgnoredSystemPrompt) {
          systemPromptEditor
            .padding(.top, SettingsConstants.internalSectionSpacing)
        } label: {
          Label(
            "System prompt — not used by \(viewModel.data.selectedTranscriptionModel.displayName)",
            systemImage: "text.alignleft"
          )
          .font(.headline)
        }

        systemPromptIgnoredBanner(ignoredReason)
      } else {
        systemPromptEditor

        SpacedSectionDivider()

        glossaryEditor
      }

      SpacedSectionDivider()

      // Usage Instructions Section
      usageInstructionsSection

      if viewModel.data.selectedTranscriptionModel.isGemini
        || viewModel.data.selectedTranscriptionModel == .openRouterTranscription
      {
        SpacedSectionDivider()
        AdvancedSettingsGroup {
          tuningSection
        }
      }
    }
  }
  
  // MARK: - Prompt and Glossary Editors

  @ViewBuilder
  private var systemPromptEditor: some View {
    SystemPromptSectionEditor(
      title: "System prompt",
      systemImage: "text.alignleft",
      subtitle: "Instructions for how to transcribe (filler words, punctuation, formatting). Used by Gemini, GPT-4o Transcribe, xAI Grok, OpenRouter and self-hosted endpoints. GPT Transcribe and offline Whisper ignore it — they take vocabulary from the Glossary instead. Keep specific terms out of here; put them in the Glossary.",
      section: .dictation,
      defaultContent: AppConstants.defaultTranscriptionSystemPrompt
    )
  }

  @ViewBuilder
  private var glossaryEditor: some View {
    SystemPromptSectionEditor(
      title: "Glossary",
      systemImage: "character.book.closed",
      subtitle: "Comma-separated vocabulary of hard-to-spell terms (names, jargon, product names). Sent to every provider, by whatever route that provider supports: conditioning text for offline Whisper, dedicated keyword hints for GPT Transcribe, appended to the instructions for Gemini, GPT-4o Transcribe and xAI Grok. Offline Whisper caps its conditioning at 224 tokens — roughly 150 terms — and drops the rest, so keep it to the words that actually get misspelled. Leave empty for no conditioning.",
      section: .whisperGlossary,
      defaultContent: AppConstants.defaultWhisperGlossary
    )

    #if !APP_STORE
    VStack(alignment: .leading, spacing: 8) {
      ShortcutRecorderRow(
        label: "Add Selection to Glossary:",
        shortcut: $viewModel.data.addToGlossary,
        focusedField: .addToGlossaryShortcut,
        currentFocus: $focusedField,
        onChanged: { Task { await viewModel.saveSettings() } },
        findConflict: viewModel.findShortcutConflict,
        clearShortcut: viewModel.clearShortcut
      )
      Text("Select a correctly spelled term anywhere — in your practice software, a document, an email — and press the shortcut to append it here. No model is involved, so this is also the way to grow the Glossary while Offline Mode is on.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, SettingsConstants.internalSectionSpacing)
    #endif
  }

  // MARK: - Shortcuts Section
  @ViewBuilder
  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Keyboard Shortcut",
        systemImage: "keyboard",
        subtitle: "Start/Stop Dictation with one shortcut"
      )

      ShortcutRecorderRow(
        label: "Toggle Dictation:",
        shortcut: $viewModel.data.toggleDictation,
        focusedField: .toggleDictation,
        currentFocus: $focusedField,
        onChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        findConflict: viewModel.findShortcutConflict,
        clearShortcut: viewModel.clearShortcut
      )

      #if !APP_STORE
      Toggle(isOn: $viewModel.data.fnKeyDictation) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Use 🌐 Fn to dictate")
            .font(.callout)
          Text("Press the Fn (Globe) key to start recording, press it again to stop and transcribe. Requires Accessibility permission. In System Settings → Keyboard, set \"Press 🌐 key to\" to \"Do Nothing\" so macOS doesn't also react to the key.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.fnKeyDictation) { _, newValue in
        DebugLogger.log("SHORTCUTS: Fn-key dictation toggled to \(newValue)")
        if newValue && !AccessibilityPermissionManager.hasAccessibilityPermission() {
          // Request now (native prompt + pre-registration), not deferred to the first fn press.
          AccessibilityPermissionManager.requestAccessibilityAtOptIn()
        }
        Task {
          await viewModel.saveSettings()
        }
      }
      #endif
    }
  }

  // MARK: - Language Section
  @ViewBuilder
  private var languageSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Language",
        systemImage: "globe",
        subtitle: "Specify the language for Whisper transcription. Auto-detect lets Whisper determine the language automatically."
      )

      Picker("Language", selection: $viewModel.data.whisperLanguage) {
        ForEach(WhisperLanguage.allCases, id: \.self) { language in
          Text(language.displayName)
            .tag(language)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onChange(of: viewModel.data.whisperLanguage) {
        Task {
          await viewModel.saveSettings()
        }
      }

      if viewModel.data.whisperLanguage.isRecommended {
        HStack {
          Image(systemName: "star.fill")
            .foregroundColor(.yellow)
            .font(.caption)
          Text("Recommended")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
        }
      }
    }
  }

  // MARK: - Model Section
  @ViewBuilder
  private var modelSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      ModelSelectionView(
        title: "Transcription Model",
        systemImage: "waveform",
        selectedTranscriptionModel: $viewModel.data.selectedTranscriptionModel,
        geminiDisabled: !GeminiCredentialProvider.shared.hasCredential(),
        openAIDisabled: !KeychainManager.shared.hasNonEmpty(.openAI),
        xaiDisabled: !KeychainManager.shared.hasNonEmpty(.xai),
        subscriptionMode: false,
        onModelChanged: {
          UserDefaults.standard.set(
            viewModel.data.selectedTranscriptionModel.rawValue,
            forKey: UserDefaultsKeys.selectedTranscriptionModel)
          NotificationCenter.default.post(
            name: .modelChanged,
            object: viewModel.data.selectedTranscriptionModel)
          Task {
            await viewModel.saveSettings()
          }
        }
      )
      if viewModel.data.selectedTranscriptionModel.isGemini && !GeminiCredentialProvider.shared.hasCredential() {
        Text("Sign in with Google or add your API key in the General tab for Gemini models. You can also select an offline Whisper model to dictate without a key.")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }

      if viewModel.data.selectedTranscriptionModel.isOpenAI && !KeychainManager.shared.hasNonEmpty(.openAI) {
        Text("Add your OpenAI API key in the General tab to use the OpenAI transcription models.")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }

      if viewModel.data.selectedTranscriptionModel == .selfHostedTranscription {
        SelfHostedTranscriptionEndpointSection()
      }

      if viewModel.data.selectedTranscriptionModel == .openRouterTranscription {
        OpenRouterTranscriptionSection(viewModel: viewModel)
      }
    }
  }

  // MARK: - Transcription Tuning Section

  /// Temperature and thinking effort for cloud transcription.
  ///
  /// Both are hidden for offline Whisper and for the OpenAI/xAI/self-hosted endpoints, which take
  /// neither: `gpt-4o-transcribe` rejects `temperature` outright, and the multipart transcription
  /// APIs have no notion of thinking.
  @ViewBuilder
  private var tuningSection: some View {
    let model = viewModel.data.selectedTranscriptionModel
    if model.isGemini || model == .openRouterTranscription {
      VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
        SectionHeader(
          title: "Accuracy Tuning",
          systemImage: "dial.medium",
          subtitle: "How freely the model may deviate from what it heard, and how long it may think first."
        )

        Picker("Temperature:", selection: $viewModel.data.transcriptionTemperature) {
          ForEach(TranscriptionTemperature.allCases, id: \.self) { value in
            Text(value.displayName).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .onChange(of: viewModel.data.transcriptionTemperature) { _, _ in
          Task { await viewModel.saveSettings() }
        }

        Text("Lower means more literal. WhisperShortcut uses 0.0, which reproduces what was said. Sending no value at all — as versions before 7.96 did — leaves the AI model on its own setting of 1.0, the most likely source of invented or swapped words.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if model.isGemini {
          Picker("Thinking effort:", selection: $viewModel.data.transcriptionThinkingEffort) {
            ForEach(TranscriptionThinkingEffort.allCases, id: \.self) { value in
              Text(value.displayName).tag(value)
            }
          }
          .pickerStyle(.segmented)
          .onChange(of: viewModel.data.transcriptionThinkingEffort) { _, _ in
            Task { await viewModel.saveSettings() }
          }

          Text("More thinking can help on hard audio, accents, and unusual vocabulary, at the cost of latency — on Flash-Lite the cost is close to zero, on Pro it roughly doubles. Gemini 3.1 Pro and Gemini 3.7 Flash cannot run below Low and are clamped to it.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - Offline Models Section
  @ViewBuilder
  private var offlineModelsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Available Models",
        systemImage: "arrow.down.circle",
        subtitle: "Download and manage offline Whisper models for transcription"
      )

      Text("Offline models allow you to transcribe audio without an internet connection. Models are automatically downloaded from HuggingFace and cached locally.")
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)

      // Available Models List
      VStack(spacing: 12) {
        ForEach(OfflineModelType.offerable, id: \.self) { modelType in
          offlineModelRow(for: modelType)
        }
      }
    }
  }

  // MARK: - Offline Model Row
  private func offlineModelRow(for modelType: OfflineModelType) -> some View {
    ModelDownloadRow(
      store: modelManager,
      model: modelType,
      downloadedMessage:
        "\(modelType.displayName) was successfully downloaded. The first transcription may take a moment to initialize the model; subsequent ones will be faster.",
      onError: { viewModel.showError($0) }
    ) {
      if modelType.isRecommended {
        HStack(spacing: 4) {
          Image(systemName: "star.fill")
            .foregroundColor(.yellow)
            .font(.caption)
          Text("Recommended")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      } else if modelType.isSuperseded {
        Text("Superseded by Large v3 Turbo")
          .font(.caption)
          .foregroundColor(.secondary)
      } else if modelType.isQuickStart {
        // Not a second "Recommended": this is the small download for trying offline out,
        // and saying so keeps it findable without competing with the actual recommendation.
        Text("Smallest download")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }

  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "How to Use",
        systemImage: "questionmark.circle",
        subtitle: "Step-by-step instructions for using dictation mode"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Press your configured shortcut")
          .textSelection(.enabled)
        Text("2. Speak your text")
          .textSelection(.enabled)
        Text("3. Press the shortcut again to stop")
          .textSelection(.enabled)
        Text("4. Transcription is automatically copied to clipboard")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }

  // MARK: - System prompt applicability

  /// Stated where the prompt is edited, not in the model picker: the picker is where you choose a
  /// model, this is where you would otherwise sit and wonder why the rule you just typed does
  /// nothing.
  @ViewBuilder
  private func systemPromptIgnoredBanner(_ reason: String) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.orange)
        .font(.caption)
      Text(reason)
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.bottom, 4)
  }

}
