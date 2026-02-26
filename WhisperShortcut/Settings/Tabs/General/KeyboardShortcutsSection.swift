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
        placeholder: ShortcutConfig.examplePlaceholder(for: ShortcutConfig.default.openSettings),
        text: $viewModel.data.openSettings,
        focusedField: .toggleSettings,
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

        Text(ShortcutConfig.availableKeysHint)
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)
    }
  }
}
