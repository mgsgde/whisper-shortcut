import SwiftUI

/// Live Meeting Settings Tab - Chunk interval and options
struct LiveMeetingSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Chunk Interval Section
      chunkIntervalSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Safeguard Section
      safeguardSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Usage Instructions Section
      usageInstructionsSection
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
        title: "How to Use",
        subtitle: "Step-by-step instructions for live meeting transcription"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Click \"Transcribe Meeting\" in the menu bar")
          .textSelection(.enabled)
        Text("2. A transcript file opens automatically in your default editor")
          .textSelection(.enabled)
        Text("3. Text appears in the file as the meeting progresses")
          .textSelection(.enabled)
        Text("4. Use the transcript with AI assistants in your editor (e.g., Cursor)")
          .textSelection(.enabled)
        Text("5. Click \"Stop Transcribe Meeting\" to end the session")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
      
      // Note about transcript location
      VStack(alignment: .leading, spacing: 4) {
        Text("Transcript location:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
        Text("~/Documents/WhisperShortcut/Meeting-<timestamp>.txt")
          .font(.system(.callout, design: .monospaced))
          .foregroundColor(.secondary)
          .textSelection(.enabled)
        Button("Open Transcript Folder") {
          viewModel.openTranscriptsFolder()
        }
        .buttonStyle(.bordered)
        .font(.callout)
      }
      .padding(8)
      .background(Color.secondary.opacity(0.1))
      .cornerRadius(6)
    }
  }
}
