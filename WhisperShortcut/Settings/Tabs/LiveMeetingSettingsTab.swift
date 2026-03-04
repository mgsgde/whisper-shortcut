import SwiftUI

/// Live Meeting Settings Tab - Chunk interval and options
struct LiveMeetingSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Keyboard Shortcut Section
      keyboardShortcutSection

      SpacedSectionDivider()

      // Chunk Interval Section
      chunkIntervalSection

      SpacedSectionDivider()

      // Transcription Model Section
      transcriptionModelSection

      SpacedSectionDivider()

      // Safeguard Section
      safeguardSection

      SpacedSectionDivider()

      // Usage Instructions Section
      usageInstructionsSection
    }
  }

  // MARK: - Keyboard Shortcut Section
  @ViewBuilder
  private var keyboardShortcutSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcut",
        subtitle: "Open the Meeting window (toggle show/hide)"
      )

      ShortcutInputRow(
        label: "Open Meeting:",
        placeholder: ShortcutConfig.examplePlaceholder(for: ShortcutConfig.default.openMeeting),
        text: $viewModel.data.openMeeting,
        focusedField: .openMeeting,
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

  // MARK: - Chunk Interval Section
  @ViewBuilder
  private var chunkIntervalSection: some View {
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
        Task {
          await viewModel.saveSettings()
        }
      }

      Text("Shorter intervals provide more responsive updates but use more API calls.")
        .font(.callout)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Transcription Model Section
  @ViewBuilder
  private var transcriptionModelSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      ModelSelectionView(
        title: "Transcription Model",
        selectedTranscriptionModel: $viewModel.data.selectedTranscriptionModelForMeetings,
        geminiDisabled: !KeychainManager.shared.hasGoogleAPIKey(),
        onModelChanged: {
          Task {
            await viewModel.saveSettings()
          }
        }
      )
      if viewModel.data.selectedTranscriptionModelForMeetings.isGemini && !KeychainManager.shared.hasGoogleAPIKey() {
        Text("API key required for Gemini models. Add your key in the General tab, or select an offline Whisper model.")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: - Safeguard Section
  @ViewBuilder
  private var safeguardSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🛡️ Safeguard",
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
          Task {
            await viewModel.saveSettings()
          }
        }

        Spacer()
      }

      Text("Choose \"Never\" to disable.")
        .font(.callout)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 How to Use",
        subtitle: "Meeting window and live transcription"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Press your shortcut or click \"Open Meeting\" in the menu bar to open the Meeting window")
          .textSelection(.enabled)
        Text("2. Click \"New Meeting\" to start a meeting (recording begins automatically)")
          .textSelection(.enabled)
        Text("3. Transcript and AI chat appear in the Meeting window as you speak")
          .textSelection(.enabled)
        Text("4. Click \"End Meeting\" to stop recording, or \"Open Meeting\" to open another meeting from the library")
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
