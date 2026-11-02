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

  #if !APP_STORE
  /// Re-read on appear and on app reactivation (the user may have just changed either in
  /// System Settings).
  @State private var hasAccessibility = AccessibilityPermissionManager.hasAccessibilityPermission()
  @State private var globeUsage: GlobeKeyUsage = .current
  @State private var liveUnavailable: LiveDictation.Unavailable?
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Keyboard Shortcuts",
        systemImage: "keyboard",
        subtitle: "Global shortcuts — they work from any app. Press a shortcut once to start, again to stop."
      )

      // Labels keep the trailing colon, and Chat/Settings keep the "Open " the form has
      // always used. The binding is a `SettingsData` field, not the `ShortcutConfig` key path.
      // Literal keys, not `"\(ShortcutAction.x.title):"`: interpolating the English `title`
      // looks up `%@:` and leaves the name untranslated.
      row("Dictate:", $viewModel.data.toggleDictation, .toggleDictation)
      row("Dictate Prompt:", $viewModel.data.togglePrompting, .togglePrompting)
      row("Screenshot:", $viewModel.data.screenshotCapture, .screenshotCapture)

      // Selection-based shortcuts copy via ⌘C (Accessibility) — not in the App Store build.
      if ShortcutAction.readAloud.isInThisBuild {
        row("Read Aloud:", $viewModel.data.readAloud, .readAloudShortcut)
      }

      // Glossary is not a `ShortcutAction` (see that enum). Same App Store exclusion as Read Aloud.
      #if !APP_STORE
      row("Add to Glossary:", $viewModel.data.addToGlossary, .addToGlossaryShortcut)
      // Text at the cursor while speaking; pastes, so the same App Store exclusion.
      row("Dictate Live:", $viewModel.data.liveDictate, .liveDictateShortcut)
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
  /// On by default when the 🌐 key is free (`SettingsDefaults.fnKeyDictation`), so the notes below
  /// say why an "on" toggle may still do nothing: no Accessibility yet, or macOS still owns 🌐.
  private var fnKeyToggle: some View {
    VStack(alignment: .leading, spacing: 8) {
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
          refreshFnStatus()
        }
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Also dictate with 🌐 Fn")
            .font(.callout)
          Text("Press Fn once to start, again to stop. Needs Accessibility.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)

      if viewModel.data.fnKeyDictation {
        HStack(alignment: .center, spacing: 12) {
          Text("Fn key starts")
            .font(.callout)
          Spacer(minLength: 16)
          Picker("", selection: Binding(
            get: { viewModel.data.fnKeyStartMode },
            set: { newValue in
              if newValue == .live && liveUnavailable != nil { return }
              viewModel.data.fnKeyStartMode = newValue
              Task { await viewModel.saveSettings() }
            }
          )) {
            ForEach(FnStartMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityLabel("Fn key starts")
          .fixedSize()
        }
        if let liveUnavailable {
          Text(verbatim: liveUnavailable.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if viewModel.data.fnKeyStartMode == .live {
          Text("Fn starts Dictate Live: text appears at the cursor after each pause.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !hasAccessibility {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .font(.caption)
            Text("Fn does nothing until WhisperShortcut is allowed under Accessibility.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Allow Accessibility") {
              AccessibilityPermissionManager.requestAccessibilityAtOptIn()
              refreshFnStatus()
            }
            .controlSize(.small)
            .pointerCursorOnHover()
          }
        }
        if let systemAction = globeUsage.systemSettingsLabel {
          GlobeKeyConflictNote(systemAction: systemAction)
        }
      }
    }
    .padding(.top, 4)
    .onAppear(perform: refreshFnStatus)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshFnStatus()
    }
  }

  private func refreshFnStatus() {
    hasAccessibility = AccessibilityPermissionManager.hasAccessibilityPermission()
    globeUsage = .current
    let model = TranscriptionModel.loadSelected()
    liveUnavailable = LiveDictation.unavailableReason(
      model: model, downloaded: model.isOfflineModelAvailable(),
      appleSilicon: LiveDictation.isAppleSilicon, duringMeeting: false)
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
