import SwiftUI

/// Read Aloud Settings Tab - Shortcut and Voice Selection
struct ReadAloudSettingsTab: View {
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

      // Read Aloud Voice Selection Section
      readAloudVoiceSection
    }
  }

  // MARK: - Shortcuts Section
  @ViewBuilder
  private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcuts",
        subtitle: "Configure shortcut for reading selected text aloud"
      )

      ShortcutInputRow(
        label: "Read Aloud:",
        placeholder: "e.g., command+4",
        text: $viewModel.data.readAloud,
        isEnabled: $viewModel.data.readAloudEnabled,
        focusedField: .toggleReadAloud,
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

  // MARK: - Read Aloud Voice Selection Section
  @ViewBuilder
  private var readAloudVoiceSection: some View {
    ReadAloudVoiceSelectionView(
      selectedVoice: $viewModel.data.selectedReadAloudVoice,
      onVoiceChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }
}

#if DEBUG
  struct ReadAloudSettingsTab_Previews: PreviewProvider {
    static var previews: some View {
      @FocusState var focusedField: SettingsFocusField?

      ReadAloudSettingsTab(viewModel: SettingsViewModel(), focusedField: $focusedField)
        .padding()
        .frame(width: 600, height: 500)
    }
  }
#endif

