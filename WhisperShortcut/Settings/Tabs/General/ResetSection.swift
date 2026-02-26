//
//  ResetSection.swift
//  WhisperShortcut
//

import SwiftUI
import AppKit

struct ResetSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @Binding var showResetToDefaultsConfirmation: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Data & Reset",
        subtitle: "Resets the app to its original state: all system prompts to default, all settings to default, model selection to default, and all user interactions deleted. API key is preserved. To delete only context data, use the Context tab."
      )

      HStack(alignment: .center, spacing: 12) {
        Button(action: { openDataFolderInFinder() }) {
          Label("Open app data folder", systemImage: "folder")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open app data folder in Finder")
        .pointerCursorOnHover()

        Button("Reset all to defaults", role: .destructive) {
          showResetToDefaultsConfirmation = true
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .help("Reset app to original state; app will quit after reset")
        .pointerCursorOnHover()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func openDataFolderInFinder() {
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    NSWorkspace.shared.open(url)
  }
}
