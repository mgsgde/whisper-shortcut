import SwiftUI

/// Chat Settings Tab — shortcut, model, voice, and live meeting settings
struct ChatSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      keyboardShortcutSection

      SpacedSectionDivider()

      modelSection

      SpacedSectionDivider()

      CustomOpenAIChatEndpointSection()

      SpacedSectionDivider()

      windowBehaviorSection

      SpacedSectionDivider()

      // Chat system prompt editor
      SystemPromptSectionEditor(
        title: "System prompt",
        systemImage: "text.alignleft",
        subtitle: "Instructions sent to the model in Chat mode. Edit to customize chat behavior.",
        section: .chat,
        defaultContent: AppConstants.defaultChatSystemPrompt
      )

      SpacedSectionDivider()

      ChatMemoryEditor()

      SpacedSectionDivider()

      WorkspaceFoldersSection()

      SpacedSectionDivider()

      GoogleCalendarConnectionSection()

      SpacedSectionDivider()

      TrelloConnectionSection()

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
        title: "Keyboard Shortcut",
        systemImage: "keyboard",
        subtitle: "Open the chat window"
      )

      ShortcutRecorderRow(
        label: "Chat:",
        shortcut: $viewModel.data.openChat,
        focusedField: .toggleChat,
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

  // MARK: - Model Section
  @ViewBuilder
  private var modelSection: some View {
    PromptModelSelectionView(
      title: "Chat model",
      subtitle: "Choose which model powers the chat. Pick **Custom endpoint** for your own OpenAI-compatible URL (configured below). Grok models require an xAI API key (Settings > General).",
      selectedModel: $viewModel.data.selectedChatModel,
      availableModels: PromptModel.chatModels,
      recommendedModel: SettingsDefaults.selectedChatModel,
      subscriptionMode: false,
      onModelChanged: {
        UserDefaults.standard.set(
          viewModel.data.selectedChatModel.rawValue,
          forKey: UserDefaultsKeys.selectedChatModel)
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
        title: "Window Behavior",
        systemImage: "macwindow",
        subtitle: "Control how the chat window behaves"
      )

      Toggle(isOn: $viewModel.data.chatCloseOnFocusLoss) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Close window when losing focus")
            .font(.callout)
          Text("Automatically closes the chat window when it loses focus.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.chatCloseOnFocusLoss) { _ in
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
        systemImage: "timer",
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
      subtitle: "Model used for the rolling summary during the meeting and the final summary when it ends",
      selectedModel: $viewModel.data.selectedMeetingSummaryModel,
      // Summary generation is a text task routed through any provider — exclude the audio-only
      // GPT-Audio model (400s on text) and image-generation models that the default list would include.
      availableModels: PromptModel.textChatModels,
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
        title: "Meeting Safeguard",
        systemImage: "shield",
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
        .accessibilityLabel("Ask when meeting longer than")
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
        title: "How to Use",
        systemImage: "questionmark.circle",
        subtitle: "Chat and live meeting"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("Use the shortcut or the menu bar item \"Chat\" to open the chat window.")
          .textSelection(.enabled)
        Text("Type /meeting in chat to start/stop live meeting recording.")
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
