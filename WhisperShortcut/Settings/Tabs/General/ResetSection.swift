//
//  ResetSection.swift
//  WhisperShortcut
//

import SwiftUI
import AppKit

struct ResetSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @Binding var showResetToDefaultsConfirmation: Bool

  @AppStorage(UserDefaultsKeys.saveRawAssistantResponses) private var saveRawAssistantResponses = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Data & Reset",
        subtitle: "Resets the app to its original state: all settings, system prompts, model selection, chat sessions, meeting transcripts, and interaction data are deleted. API keys are preserved. To delete only context data, use the Context tab."
      )

      HStack(alignment: .center, spacing: 12) {
        Button(action: { openDataFolderInFinder() }) {
          Label("Open app data folder", systemImage: "folder")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open app data folder in Finder")
        .pointerCursorOnHover()

        Button(action: { openLogsFolderInFinder() }) {
          Label("Show logs", systemImage: "doc.text.magnifyingglass")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open the daily log folder in Finder — useful when filing bug reports")
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

      VStack(alignment: .leading, spacing: 6) {
        Toggle("Save raw assistant responses to disk", isOn: $saveRawAssistantResponses)
          .help("Diagnostics: dumps each final chat response as a .md file so markdown-rendering bugs can be reproduced from the exact model output. Off by default.")
        if saveRawAssistantResponses {
          Button(action: { openRawResponsesFolderInFinder() }) {
            Label("Open raw responses folder", systemImage: "folder.badge.gearshape")
              .font(.callout)
          }
          .buttonStyle(.bordered)
          .pointerCursorOnHover()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func openDataFolderInFinder() {
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }

  private func openLogsFolderInFinder() {
    let url = AppSupportPaths.logsURL()
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }

  private func openRawResponsesFolderInFinder() {
    let url = AppSupportPaths.debugRawResponsesURL()
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }
}
