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

      // Labels keep the trailing colon, and Chat/Settings keep the "Open " the form has
      // always used. The binding is a `SettingsData` field, not the `ShortcutConfig` key path.
      row("\(ShortcutAction.dictate.title):", $viewModel.data.toggleDictation, .toggleDictation)
      row("\(ShortcutAction.dictatePrompt.title):", $viewModel.data.togglePrompting, .togglePrompting)
      row("\(ShortcutAction.screenshot.title):", $viewModel.data.screenshotCapture, .screenshotCapture)

      // Selection-based shortcuts copy via ⌘C (Accessibility) — not in the App Store build.
      if ShortcutAction.readAloud.isInThisBuild {
        row("\(ShortcutAction.readAloud.title):", $viewModel.data.readAloud, .readAloudShortcut)
      }

      // Glossary is not a `ShortcutAction` (see that enum). Same App Store exclusion as Read Aloud.
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
    // The permission prompt lives in the binding's setter, not `onChange`: `onChange` also fires
    // when `data` is reloaded programmatically, which must never trigger a system prompt. The
    // setter only runs when the user flips this toggle.
    Toggle(isOn: Binding(
      get: { viewModel.data.fnKeyDictation },
      set: { newValue in
        DebugLogger.log("SHORTCUTS: Fn-key dictation toggled to \(newValue)")
        if newValue && !AccessibilityPermissionManager.hasAccessibilityPermission() {
          // Request now (native prompt + pre-registration), not deferred to the first fn press.
          AccessibilityPermissionManager.requestAccessibilityAtOptIn()
        }
        viewModel.data.fnKeyDictation = newValue
        Task { await viewModel.saveSettings() }
      }
    )) {
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
