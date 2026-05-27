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

      ShortcutRecorderRow(
        label: "Toggle Settings:",
        shortcut: $viewModel.data.openSettings,
        focusedField: .toggleSettings,
        currentFocus: $focusedField,
        onChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        findConflict: viewModel.findShortcutConflict,
        clearShortcut: viewModel.clearShortcut
      )

      ShortcutRecorderRow(
        label: "Screenshot to Clipboard:",
        shortcut: $viewModel.data.screenshotCapture,
        focusedField: .screenshotCapture,
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
}
