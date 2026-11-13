//
//  DictationOnlySection.swift
//  WhisperShortcut
//

import SwiftUI

/// Settings → General: the "Dictation only" switch. It only hides and shows
/// (`DictationOnlySettingsSwitch`); the first-run defaults belong to the onboarding card alone.
/// Spec: plans/active/dictation-only-mode.md, decisions 3, 4 and 6.
struct DictationOnlySection: View {
  @AppStorage(UserDefaultsKeys.dictationOnlyMode) private var isOn = false
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false
  /// Set when the switch was refused because something is running; cleared on the next try.
  @State private var refused = false
  /// Switched off in this visit while Offline Mode is on: say once that Offline Mode stays.
  @State private var switchedOffThisVisit = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(isOn: Binding(get: { isOn }, set: change)) {
        Text("Dictation only")
          .font(.headline)
          // Switch on the trailing edge, like the other switches in Settings.
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .toggleStyle(.switch)

      VStack(alignment: .leading, spacing: 4) {
        Text("Shows only dictation. Chat, meetings, AI rewriting and the other features are hidden.")
        Text("Nothing is deleted. When you switch it off, your shortcuts and settings are back.")
      }
      .font(.callout)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      if refused {
        Label(
          "Not possible right now: a recording or meeting is running. Try again when it has finished.",
          systemImage: "exclamationmark.circle"
        )
        .font(.callout)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      } else if switchedOffThisVisit && !isOn && offlineMode {
        Label(
          "Offline Mode stays on. You can switch it off in Permissions & Privacy.",
          systemImage: "info.circle"
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(SettingsConstants.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .stroke(isOn ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  private func change(_ enabled: Bool) {
    switch DictationOnlySettingsSwitch.change(to: enabled, activity: DictationOnlyMode.currentActivity) {
    case .changed:
      refused = false
      switchedOffThisVisit = !enabled
    case .refusedWhileBusy:
      // The stored flag did not change, so the switch snaps back on its own.
      refused = true
    }
  }
}
