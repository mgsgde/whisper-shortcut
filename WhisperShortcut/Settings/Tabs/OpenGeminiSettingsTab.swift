import SwiftUI

/// Chat Settings Tab — shortcut, model, voice, and live meeting settings
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

      // Chat system prompt editor
      SystemPromptSectionEditor(
        title: "System prompt",
        subtitle: "Instructions sent to the model in Chat mode. Edit to customize chat behavior.",
        section: .geminiChat,
        defaultContent: AppConstants.defaultGeminiChatSystemPrompt
      )

      SpacedSectionDivider()

      GoogleCalendarConnectionSection()

      SpacedSectionDivider()

      meetingChunkIntervalSection

      SpacedSectionDivider()

      meetingTranscriptionModelSection

      SpacedSectionDivider()

      meetingSummaryModelSection

      SpacedSectionDivider()

      meetingSafeguardSection

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
        subtitle: "Open the chat window"
      )

      ShortcutInputRow(
        label: "Chat:",
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
      title: "Chat model",
      subtitle: "Choose which model powers the chat. Grok models require an xAI API key (Settings > General).",
      selectedModel: $viewModel.data.selectedOpenGeminiModel,
      availableModels: PromptModel.chatModels,
      subscriptionMode: false,
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
        subtitle: "Control how the chat window behaves"
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

  // MARK: - Meeting Chunk Interval Section
  @ViewBuilder
  private var meetingChunkIntervalSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Chunk Interval",
        subtitle: "How often the audio is transcribed and added to the file"
      )

      Picker("Interval:", selection: $viewModel.data.liveMeetingChunkInterval) {
        ForEach(LiveMeetingChunkInterval.allCases, id: \.self) { interval in
          Text(interval.displayName).tag(interval)
        }
      }
      .pickerStyle(.segmented)
      .onChange(of: viewModel.data.liveMeetingChunkInterval) { _, _ in
        Task { await viewModel.saveSettings() }
      }

      Text("Shorter intervals provide more responsive updates but use more API calls.")
        .font(.callout)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Meeting Transcription Model Section
  @ViewBuilder
  private var meetingTranscriptionModelSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      ModelSelectionView(
        title: "Meeting Transcription Model",
        selectedTranscriptionModel: $viewModel.data.selectedTranscriptionModelForMeetings,
        geminiDisabled: !GeminiCredentialProvider.shared.hasCredential(),
        onModelChanged: {
          Task { await viewModel.saveSettings() }
        }
      )
      if viewModel.data.selectedTranscriptionModelForMeetings.isGemini && !GeminiCredentialProvider.shared.hasCredential() {
        Text("Sign in with Google or add your API key in the General tab for Gemini models. You can also select an offline Whisper model.")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: - Meeting Summary Model Section
  @ViewBuilder
  private var meetingSummaryModelSection: some View {
    PromptModelSelectionView(
      title: "Meeting Summary Model",
      subtitle: "Gemini model used for rolling summary during the meeting and for the final summary when the meeting ends",
      selectedModel: $viewModel.data.selectedMeetingSummaryModel,
      onModelChanged: {
        Task { await viewModel.saveSettings() }
      }
    )
  }

  // MARK: - Meeting Safeguard Section
  @ViewBuilder
  private var meetingSafeguardSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🛡️ Meeting Safeguard",
        subtitle: "Ask after this duration to optionally stop the meeting or continue transcribing"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Ask when meeting longer than:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.liveMeetingSafeguardDuration) {
          ForEach(MeetingSafeguardDuration.allCases, id: \.rawValue) { duration in
            Text(duration.displayName).tag(duration)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.liveMeetingSafeguardDuration) { _, _ in
          Task { await viewModel.saveSettings() }
        }

        Spacer()
      }

      Text("Choose \"Never\" to disable.")
        .font(.callout)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Usage Section
  @ViewBuilder
  private var usageSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 How to Use",
        subtitle: "Chat and live meeting"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("Use the shortcut or the menu bar item \"Chat\" to open the chat window.")
          .textSelection(.enabled)
        Text("Type /meeting or use the Meeting shortcut to start/stop live meeting recording.")
          .textSelection(.enabled)
        Text("While recording, Gemini has access to the meeting transcript for context.")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)

      HStack(alignment: .center, spacing: 12) {
        Button(action: { viewModel.openTranscriptsFolder() }) {
          Label("Open transcripts folder", systemImage: "folder")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open transcripts folder in Finder")
        .pointerCursorOnHover()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
