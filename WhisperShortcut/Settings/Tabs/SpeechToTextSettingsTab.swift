import SwiftUI

/// Speech to Text Settings Tab - Shortcuts, Prompt, Transcription Model
struct SpeechToTextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @ObservedObject var modelManager = ModelManager.shared
  @State private var successMessage: String?
  @State private var showSuccess = false
  @State private var refreshTrigger = UUID() // Trigger to force view refresh

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

      // Conditional sections based on model type
      if viewModel.data.selectedTranscriptionModel.isGemini {
        // Prompt Section (only for Gemini)
        promptSection
        
        SpacedSectionDivider()
      } else {
        // Language Section (only for Whisper)
        languageSection
        
        SpacedSectionDivider()
      }

      // Usage Instructions Section
      usageInstructionsSection
    }
    .alert("Success", isPresented: $showSuccess) {
      Button("OK") {
        showSuccess = false
        successMessage = nil
      }
    } message: {
      if let successMessage = successMessage {
        Text(successMessage)
          .textSelection(.enabled)
      }
    }
  }
  
  // MARK: - Shortcuts Section
  @ViewBuilder
  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Toggle Shortcut",
        subtitle: "Start/Stop Dictation with one shortcut"
      )

      ShortcutInputRow(
        label: "Toggle Dictation:",
        placeholder: "e.g., command+e",
        text: $viewModel.data.toggleDictation,
        isEnabled: $viewModel.data.toggleDictationEnabled,
        focusedField: .toggleDictation,
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
          "command • option • control • shift • a-z • 0-9 • f1-f12 • escape • up • down • left • right • comma • period"
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)
    }
  }

  // MARK: - Prompt Section (Dictation)
  @ViewBuilder
  private var promptSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      PromptTextEditor(
        title: "💬 System Prompt",
        subtitle:
          "Domain context, formatting rules, and other instructions. Only used for Gemini models (not Whisper). Leave empty to use Gemini's default.",
        helpText:
          "Enter a single system prompt: domain terms, jargon, or any instructions for transcription. This prompt is only applied when using Gemini models.",
        defaultValue: AppConstants.defaultTranscriptionSystemPrompt,
        text: $viewModel.data.customPromptText,
        focusedField: .customPrompt,
        currentFocus: $focusedField,
        onTextChanged: {
          Task {
            await viewModel.saveSettings()
          }
        }
      )
    }
  }

  // MARK: - Language Section
  @ViewBuilder
  private var languageSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🌐 Language",
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
        title: "🎤 Transcription Model",
        selectedTranscriptionModel: $viewModel.data.selectedTranscriptionModel,
        geminiDisabled: !KeychainManager.shared.hasGoogleAPIKey(),
        onModelChanged: {
          Task {
            await viewModel.saveSettings()
          }
        }
      )
      if viewModel.data.selectedTranscriptionModel.isGemini && !KeychainManager.shared.hasGoogleAPIKey() {
        Text("API key required for Gemini models. Add your key in the General tab, or select an offline Whisper model to dictate without a key.")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: - Offline Models Section
  @ViewBuilder
  private var offlineModelsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📦 Available Models",
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
      .padding(.top, SettingsConstants.internalSectionSpacing)
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
        } else {
          // Download button
          Button("Download") {
            downloadOfflineModel(modelType)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
      }
    }
    .padding(12)
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
          
          // Show success message
          successMessage = "\(modelType.displayName) was successfully downloaded.\n\nNote: The first execution may take longer as the model needs to be initialized. Subsequent prompts will be faster."
          showSuccess = true
          
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
        title: "📋 How to Use",
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
}
