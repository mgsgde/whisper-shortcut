import SwiftUI

/// Live Meeting Settings Tab - Chunk interval, timestamps, and silent chunk handling
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

      // Timestamps Section
      timestampsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Silent Chunks Section
      silentChunksSection

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

  // MARK: - Timestamps Section
  @ViewBuilder
  private var timestampsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Timestamps",
        subtitle: "Add time markers to each chunk in the transcript"
      )

      Toggle("Show timestamps [MM:SS]", isOn: $viewModel.data.liveMeetingShowTimestamps)
        .toggleStyle(.checkbox)
        .onChange(of: viewModel.data.liveMeetingShowTimestamps) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

      Text("When enabled, each chunk will be prefixed with a timestamp showing the elapsed time since the meeting started.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      
      // Preview
      VStack(alignment: .leading, spacing: 4) {
        Text("Preview:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
        
        if viewModel.data.liveMeetingShowTimestamps {
          Text("[00:00] Welcome to the meeting...")
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(.secondary)
          Text("[00:15] First item on the agenda...")
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(.secondary)
        } else {
          Text("Welcome to the meeting...")
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(.secondary)
          Text("First item on the agenda...")
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(.secondary)
        }
      }
      .padding(8)
      .background(Color.secondary.opacity(0.1))
      .cornerRadius(6)
    }
  }

  // MARK: - Silent Chunks Section
  @ViewBuilder
  private var silentChunksSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Silent Chunks",
        subtitle: "How to handle chunks with no detected speech"
      )

      Toggle("Skip silent chunks", isOn: $viewModel.data.liveMeetingSkipSilentChunks)
        .toggleStyle(.checkbox)
        .onChange(of: viewModel.data.liveMeetingSkipSilentChunks) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

      Text("When enabled, chunks with no detected speech will not be added to the transcript file.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
      }
      .padding(8)
      .background(Color.secondary.opacity(0.1))
      .cornerRadius(6)
    }
  }
}
