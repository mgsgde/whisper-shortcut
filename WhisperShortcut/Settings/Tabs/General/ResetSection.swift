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
    }
  }

  private func openDataFolderInFinder() {
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    NSWorkspace.shared.open(url)
  }

  /// Opens the daily log directory for the currently-running build. Resolves via the same
  /// FileManager API as DebugLogger, so sandboxed and non-sandboxed builds each land in
  /// their own correct folder automatically.
  private func openLogsFolderInFinder() {
    let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let url = libraryDir.appendingPathComponent("Logs/WhisperShortcut")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }
}
