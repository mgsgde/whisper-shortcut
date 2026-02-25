//
//  KeyboardShortcutsSection.swift
//  WhisperShortcut
//

import SwiftUI

struct KeyboardShortcutsSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcut",
        subtitle: "Configure keyboard shortcuts for various features"
      )

      ShortcutInputRow(
        label: "Toggle Settings:",
        placeholder: "e.g., command+6",
        text: $viewModel.data.openSettings,
        isEnabled: $viewModel.data.openSettingsEnabled,
        focusedField: .toggleSettings,
        currentFocus: $focusedField,
        onShortcutChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        validateShortcut: viewModel.validateShortcut
      )

      ShortcutInputRow(
        label: "Open Gemini:",
        placeholder: "e.g., command+8",
        text: $viewModel.data.openGemini,
        isEnabled: $viewModel.data.openGeminiEnabled,
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
}
