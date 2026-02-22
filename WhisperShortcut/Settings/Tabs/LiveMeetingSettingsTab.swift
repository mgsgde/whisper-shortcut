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
        subtitle: "Start and stop meeting transcription with the same shortcut"
      )

      ShortcutInputRow(
        label: "Transcribe Meeting:",
        placeholder: "e.g., command+5",
        text: $viewModel.data.toggleMeeting,
        isEnabled: $viewModel.data.toggleMeetingEnabled,
        focusedField: .toggleMeeting,
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
        subtitle: "Step-by-step instructions for live meeting transcription"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Press your shortcut or click \"Transcribe Meeting\" in the menu bar")
          .textSelection(.enabled)
        Text("2. A transcript file opens automatically in your default editor")
          .textSelection(.enabled)
        Text("3. Text appears in the file as the meeting progresses")
          .textSelection(.enabled)
        Text("4. Use the transcript with AI assistants in your editor (e.g., Cursor)")
          .textSelection(.enabled)
        Text("5. Press the shortcut again or click \"Stop Transcribe Meeting\" to end the session")
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
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
