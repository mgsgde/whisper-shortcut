//
//  ClipboardBehaviorSection.swift
//  WhisperShortcut
//

import SwiftUI

struct ClipboardBehaviorSection: View {
  @ObservedObject var viewModel: SettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 Clipboard Behavior",
        subtitle: "Configure what happens after dictation or prompt mode completes"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Auto-paste:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: $viewModel.data.autoPasteAfterDictation)
          .toggleStyle(SwitchToggleStyle())
          .onChange(of: viewModel.data.autoPasteAfterDictation) { _, newValue in
            if newValue && !AccessibilityPermissionManager.hasAccessibilityPermission() {
              AccessibilityPermissionManager.showAccessibilityPermissionDialog()
            }
            Task {
              await viewModel.saveSettings()
            }
          }

        Spacer()
      }

      Text("When enabled, transcriptions and AI responses are automatically pasted at the cursor position (simulates ⌘V). Works for Dictate and Prompt Mode. Requires Accessibility permission.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
