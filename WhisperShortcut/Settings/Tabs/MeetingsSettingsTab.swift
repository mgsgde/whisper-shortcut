import SwiftUI

/// Meetings Settings Tab — live meeting recording: which models transcribe and summarize, the
/// flag-a-moment shortcut, access for other AI apps, and the rarely touched timing knobs.
///
/// Split out of Chat, where these sat under "Advanced" between the chat's own settings and were
/// hard to find for anyone who records meetings and never opens the chat otherwise.
struct MeetingsSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      howItWorksSection

      SpacedSectionDivider()

      meetingTranscriptionModelSection

      SpacedSectionDivider()

      meetingSummaryModelSection

      SpacedSectionDivider()

      meetingMarkerSection

      SpacedSectionDivider()

      MeetingsInAIAppsSection()

      SpacedSectionDivider()

      AdvancedSettingsGroup {
        meetingChunkIntervalSection
        meetingSafeguardSection
      }
    }
  }

  // MARK: - How It Works Section
  @ViewBuilder
  private var howItWorksSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Meetings",
        systemImage: "record.circle",
        subtitle: "Record a meeting from the chat window: type /meeting, or click the record button next to Meetings in the sidebar. The transcript is written as you talk, summarized when you stop, and you can ask the chat about it at any point."
      )

      Button(action: { viewModel.openTranscriptsFolder() }) {
        Label("Open transcripts folder", systemImage: "folder")
          .font(.callout)
      }
      .buttonStyle(.bordered)
      .help("Open transcripts folder in Finder")
      .pointerCursorOnHover()
    }
  }

  // MARK: - Meeting Marker Section
  @ViewBuilder
  private var meetingMarkerSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Flag Meeting Moment",
        systemImage: "star",
        subtitle: "Press this while a meeting is recording to flag the current moment. The marker appears in the live notes and the final summary is written around what you flagged."
      )

      ShortcutHintRow(label: "Shortcut:", shortcut: viewModel.data.meetingMarker)

      Text("Does nothing when no meeting is recording.")
        .font(.caption)
        .foregroundColor(.secondary)
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
        Text("Sign in with Google or add your API key in Settings → Accounts for Gemini models. You can also select an offline Whisper model.")
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
      recommendedModel: SettingsDefaults.selectedMeetingSummaryModel,
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

}
