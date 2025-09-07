import SwiftUI

/// Read Clipboard Settings Tab - Shortcut, TTS Playback Speed, Usage Instructions
struct ReadClipboardSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Shortcuts Section
      shortcutsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Playback Speed Section
      playbackSpeedSection

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

  // MARK: - Shortcuts Section
  @ViewBuilder
  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Read Clipboard Shortcut",
        subtitle: "Use text-to-speech to read aloud the current clipboard content"
      )

      ShortcutInputRow(
        label: "Read Clipboard:",
        placeholder: "e.g., command+4",
        text: $viewModel.data.readClipboard,
        isEnabled: $viewModel.data.readClipboardEnabled,
        focusedField: .readClipboard,
        currentFocus: $focusedField,
        onShortcutChanged: {
          Task {
            await viewModel.saveSettings()
          }
        }
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

  // MARK: - Playback Speed Section
  @ViewBuilder
  private var playbackSpeedSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Text-to-Speech Playback Speed",
        subtitle: "Adjust how fast the clipboard text is read aloud"
      )

      HStack {
        Text("Speed:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Slider(value: $viewModel.data.readClipboardPlaybackSpeed, in: 0.25...2.0, step: 0.25) {
          Text("Playback Speed")
        }
        .frame(maxWidth: 300)
        .onChange(of: viewModel.data.readClipboardPlaybackSpeed) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Text("\(viewModel.data.readClipboardPlaybackSpeed, specifier: "%.2f")x")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: 50, alignment: .leading)
      }
    }
  }

  // MARK: - Usage Instructions Section
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "How to Use",
        subtitle: "Simple instructions for reading clipboard content"
      )

      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          Text("1.")
            .font(.body)
            .fontWeight(.semibold)
            .foregroundColor(.primary)
            .frame(width: 20, alignment: .leading)

          VStack(alignment: .leading, spacing: 4) {
            Text("Copy text to clipboard")
              .font(.body)
              .fontWeight(.medium)
              .textSelection(.enabled)

            Text("Copy any text you want to hear read aloud (⌘C or right-click → Copy)")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
          }
        }

        HStack(alignment: .top, spacing: 12) {
          Text("2.")
            .font(.body)
            .fontWeight(.semibold)
            .foregroundColor(.primary)
            .frame(width: 20, alignment: .leading)

          VStack(alignment: .leading, spacing: 4) {
            Text("Press your shortcut")
              .font(.body)
              .fontWeight(.medium)
              .textSelection(.enabled)

            Text("Use the configured keyboard shortcut to start text-to-speech")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
          }
        }

        HStack(alignment: .top, spacing: 12) {
          Text("3.")
            .font(.body)
            .fontWeight(.semibold)
            .foregroundColor(.primary)
            .frame(width: 20, alignment: .leading)

          VStack(alignment: .leading, spacing: 4) {
            Text("Listen to the content")
              .font(.body)
              .fontWeight(.medium)
              .textSelection(.enabled)

            Text("The clipboard text will be read aloud using text-to-speech")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
          }
        }

      }
    }
  }
}

#if DEBUG
  struct ReadClipboardSettingsTab_Previews: PreviewProvider {
    static var previews: some View {
      @FocusState var focusedField: SettingsFocusField?

      ReadClipboardSettingsTab(viewModel: SettingsViewModel(), focusedField: $focusedField)
        .padding()
        .frame(width: 600, height: 500)
    }
  }
#endif
