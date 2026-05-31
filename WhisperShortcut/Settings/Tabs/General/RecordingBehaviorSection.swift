//
//  RecordingBehaviorSection.swift
//  WhisperShortcut
//

import SwiftUI

struct RecordingBehaviorSection: View {
  @ObservedObject var viewModel: SettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⏯️ Recording Behavior",
        subtitle: "Control what happens to other audio while you record"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Pause media:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: $viewModel.data.pauseMediaDuringRecording)
          .toggleStyle(SwitchToggleStyle())
          .onChange(of: viewModel.data.pauseMediaDuringRecording) { _, newValue in
            DebugLogger.log("MEDIA-PAUSE SETTINGS: Toggle changed to \(newValue), hasAccessibility=\(AccessibilityPermissionManager.hasAccessibilityPermission())")
            if newValue && !AccessibilityPermissionManager.hasAccessibilityPermission() {
              AccessibilityPermissionManager.showAccessibilityPermissionDialog()
            }
            Task {
              await viewModel.saveSettings()
            }
          }

        Spacer()
      }

      Text("When enabled, recording presses the system play/pause key so background music or video pauses while you record and resumes when you stop. It works with any player (Music, Spotify, browser videos) and does not interrupt calls in Teams, Zoom or Meet. Note: because it uses the play/pause toggle, it can briefly start playback if nothing was playing when you start recording. Requires Accessibility permission.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
