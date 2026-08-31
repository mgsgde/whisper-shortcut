import SwiftUI

/// Speech to Text Settings Tab - Shortcuts, Prompt, Transcription Model
struct SpeechToTextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @ObservedObject var modelManager = ModelManager.shared
  @State private var refreshTrigger = UUID() // Trigger to force view refresh

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Shortcuts Section
      shortcutsSection

      SpacedSectionDivider()

      // Transcription Model Section
      modelSection

      SpacedSectionDivider()

      // Temperature / thinking effort (cloud models only)
      tuningSection

      SpacedSectionDivider()

      // Available Models Section
      offlineModelsSection

      SpacedSectionDivider()

      // Language Section (only for Whisper)
      if !viewModel.data.selectedTranscriptionModel.isGemini {
        languageSection
        SpacedSectionDivider()
      }

      // Dictation system prompt editor.
      //
      // The subtitle used to name "OpenAI Transcribe" among the models that use this prompt. That
      // was wrong for `gpt-transcribe`, which the request builder deliberately does not forward it
      // to — so anyone dictating with it kept every filler word while the editor above claimed
      // otherwise. The list now names only models that act on it, and the banner below states the
      // exception for whichever model is actually selected.
      if let ignoredReason = viewModel.data.selectedTranscriptionModel.systemPromptIgnoredReason {
        systemPromptIgnoredBanner(ignoredReason)
      }

      SystemPromptSectionEditor(
        title: "System prompt",
        systemImage: "text.alignleft",
        subtitle: "Instructions for how to transcribe (filler words, punctuation, formatting). Used by Gemini, GPT-4o Transcribe, xAI Grok, OpenRouter and self-hosted endpoints. GPT Transcribe and offline Whisper ignore it — they take vocabulary from the Glossary below instead. Keep specific terms out of here; put them in the Glossary.",
        section: .dictation,
        defaultContent: AppConstants.defaultTranscriptionSystemPrompt
      )

      SpacedSectionDivider()

      // Glossary editor
      SystemPromptSectionEditor(
        title: "Glossary",
        systemImage: "character.book.closed",
        subtitle: "Comma-separated vocabulary of hard-to-spell terms (names, jargon, product names). Sent to every provider, by whatever route that provider supports: conditioning text for offline Whisper, dedicated keyword hints for GPT Transcribe, appended to the instructions for Gemini, GPT-4o Transcribe and xAI Grok. Leave empty for no conditioning.",
        section: .whisperGlossary,
        defaultContent: AppConstants.defaultWhisperGlossary
      )

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
        ForEach(OfflineModelType.allCases, id: \.self) { modelType in
          offlineModelRow(for: modelType)
            .id("\(modelType.rawValue)-\(refreshTrigger)") // Force refresh when trigger changes
        }
      }
    }
  }

  // MARK: - Offline Model Row
  @ViewBuilder
  private func offlineModelRow(for modelType: OfflineModelType) -> some View {
    // Check if model is currently downloading (takes precedence)
    let isDownloading = modelManager.downloadingModels.contains(modelType)
    // Only check availability if not downloading (prevents "Downloaded / 0 MB" glitch)
    let isAvailable = !isDownloading && ModelManager.shared.isModelAvailable(modelType)
    let modelSize = ModelManager.shared.getModelSize(modelType)

    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 12) {
        // Model Info
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(modelType.displayName)
              .font(.body)
              .fontWeight(.semibold)

            if modelType.isRecommended {
              HStack(spacing: 4) {
                Image(systemName: "star.fill")
                  .foregroundColor(.yellow)
                  .font(.caption)
                Text("Recommended")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }

          HStack(spacing: 12) {
            // Status - prioritize downloading status
            HStack(spacing: 4) {
              if isDownloading {
                Image(systemName: "arrow.down.circle.fill")
                  .foregroundColor(.blue)
                  .font(.caption)
                Text("Downloading...")
                  .font(.caption)
                  .foregroundColor(.secondary)
              } else {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle")
                  .foregroundColor(isAvailable ? .green : .secondary)
                  .font(.caption)
                Text(isAvailable ? "Downloaded" : "Not downloaded")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }

            // Size - only show if not downloading and model is available
            if !isDownloading, let size = modelSize {
              Text("• \(ModelManager.shared.formatSize(size))")
                .font(.caption)
                .foregroundColor(.secondary)
            } else if !isDownloading {
              Text("• ~\(modelType.estimatedSizeMB) MB")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }

        Spacer()

        // Action Button
        if isDownloading {
          // Download in progress
          HStack(spacing: 8) {
            ProgressView()
              .scaleEffect(0.8)
            Text("Downloading...")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        } else if isAvailable {
          // Delete button
          Button("Delete") {
            deleteOfflineModel(modelType)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .foregroundColor(.red)
          .pointerCursorOnHover()
        } else {
          // Download button
          Button("Download") {
            downloadOfflineModel(modelType)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .pointerCursorOnHover()
        }
      }
    }
    .padding(SettingsConstants.rowPadding)
    .background(Color(.controlBackgroundColor))
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(.separatorColor), lineWidth: 1)
    )
  }

  // MARK: - Offline Models Actions
  private func downloadOfflineModel(_ modelType: OfflineModelType) {
    // ModelManager now handles the downloading state internally
    Task {
      do {
        try await ModelManager.shared.downloadModel(modelType)
        await MainActor.run {
          DebugLogger.logSuccess("OFFLINE-UI: Successfully downloaded \(modelType.displayName)")
          // Use the same status-bar-level popup the rest of the app uses for
          // dictation/prompt feedback. It sits above the Settings window
          // regardless of focus/window-level/closeOnFocusLoss.
          // 10s — longer than the 1s info default; this is a rare event with
          // important first-run info, so the user needs time to read it.
          PopupNotificationWindow.showInfo(
            "\(modelType.displayName) was successfully downloaded. The first transcription may take a moment to initialize the model; subsequent ones will be faster.",
            title: "Model Downloaded",
            customDisplayDuration: 10
          )

          // Give WhisperKit a moment to finish writing files
          Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
              // Trigger view update to show new model status
              refreshTrigger = UUID()
              DebugLogger.log("OFFLINE-UI: Refreshed view after download")
            }
          }
        }
      } catch {
        await MainActor.run {
          viewModel.showError("Failed to download \(modelType.displayName): \(SpeechErrorFormatter.formatForUser(error))")
          DebugLogger.logError("OFFLINE-UI: Failed to download \(modelType.displayName): \(error.localizedDescription)")
        }
      }
    }
  }

  private func deleteOfflineModel(_ modelType: OfflineModelType) {
    do {
      try ModelManager.shared.deleteModel(modelType)
      DebugLogger.logSuccess("OFFLINE-UI: Successfully deleted \(modelType.displayName)")
      // Trigger view update to show new model status
      refreshTrigger = UUID()
    } catch {
      viewModel.showError("Failed to delete \(modelType.displayName): \(SpeechErrorFormatter.formatForUser(error))")
      DebugLogger.logError("OFFLINE-UI: Failed to delete \(modelType.displayName): \(error.localizedDescription)")
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
