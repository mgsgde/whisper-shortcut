//
//  KeyboardShortcutsSection.swift
//  WhisperShortcut
//

import SwiftUI

/// Every global shortcut, editable, in one place (UX review #15).
///
/// Each feature tab used to open with its own "Keyboard Shortcut" section: set once, then in the
/// way of the model and prompt people actually come back for, and no tab showed whether the
/// combination was already taken elsewhere. Feature tabs now end with a one-line
/// `ShortcutHintRow` that links here. Order matches the status menu (digits 1-2-3-4-5).
struct KeyboardShortcutsSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Keyboard Shortcuts",
        systemImage: "keyboard",
        subtitle: "Global shortcuts — they work from any app. Press a shortcut once to start, again to stop."
      )

      row("Dictate:", $viewModel.data.toggleDictation, .toggleDictation)
      row("Dictate Prompt:", $viewModel.data.togglePrompting, .togglePrompting)
      row("Screenshot:", $viewModel.data.screenshotCapture, .screenshotCapture)

      // Selection-based shortcuts copy via ⌘C (Accessibility) — not in the App Store build.
      #if !APP_STORE
      row("Read Aloud:", $viewModel.data.readAloud, .readAloudShortcut)
      #endif

      #if !APP_STORE
      row("Add to Glossary:", $viewModel.data.addToGlossary, .addToGlossaryShortcut)
      #endif

      row("Open Chat:", $viewModel.data.openChat, .toggleChat)
      row("Open Settings:", $viewModel.data.openSettings, .toggleSettings)

      #if !APP_STORE
      fnKeyToggle
      #endif
    }
  }

  private func row(
    _ label: LocalizedStringKey, _ shortcut: Binding<ShortcutDefinition?>, _ field: SettingsFocusField
  ) -> some View {
    ShortcutRecorderRow(
      label: label,
      shortcut: shortcut,
      focusedField: field,
      currentFocus: $focusedField,
      onChanged: { Task { await viewModel.saveSettings() } },
      findConflict: viewModel.findShortcutConflict,
      clearShortcut: viewModel.clearShortcut
    )
  }

  #if !APP_STORE
  /// Alternative trigger for Dictate. Last, so it does not break the scannable list of combinations.
  private var fnKeyToggle: some View {
    Toggle(isOn: $viewModel.data.fnKeyDictation) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Also dictate with 🌐 Fn")
          .font(.callout)
        Text("Press Fn once to start, again to stop. Needs Accessibility. In System Settings → Keyboard, set \"Press 🌐 key to\" to \"Do Nothing\".")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .toggleStyle(.switch)
    .padding(.top, 4)
    .onChange(of: viewModel.data.fnKeyDictation) { _, newValue in
      DebugLogger.log("SHORTCUTS: Fn-key dictation toggled to \(newValue)")
      if newValue && !AccessibilityPermissionManager.hasAccessibilityPermission() {
        // Request now (native prompt + pre-registration), not deferred to the first fn press.
        AccessibilityPermissionManager.requestAccessibilityAtOptIn()
      }
      Task { await viewModel.saveSettings() }
    }
  }
  #endif
}

/// One line at the bottom of a feature tab (or inside the section the shortcut belongs to):
/// the current binding, and a way to the one place it is edited.
struct ShortcutHintRow: View {
  let label: LocalizedStringKey
  let shortcut: ShortcutDefinition?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "keyboard")
        .foregroundColor(.secondary)
      Text(label)
        .foregroundColor(.secondary)
      if let shortcut {
        Text(shortcut.displayString)
          .font(.system(.callout, design: .rounded))
          .fontWeight(.medium)
      } else {
        Text("Not set")
          .foregroundColor(.secondary)
      }
      Button("Change…") {
        SettingsManager.shared.showSettings(tab: .general)
      }
      .buttonStyle(.link)
      .help("Shortcuts are set in Settings → General.")
      Spacer()
    }
    .font(.callout)
  }
}
