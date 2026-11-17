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
  /// Bumped when "Dictation only" changes so the rows below are read again.
  @State private var modeRevision = 0

  #if !APP_STORE
  /// Re-read on appear and on app reactivation (the user may have just changed it in System
  /// Settings). The 🌐 setting is `GlobeKeyStatus`, refreshed by `GlobeKeyConflictCard`.
  @State private var hasAccessibility = AccessibilityPermissionManager.hasAccessibilityPermission()
  #endif

  /// Whether `slot` is shown: only shortcuts that register are listed while "Dictation only" is on.
  private func shows(_ slot: ShortcutSlot) -> Bool {
    _ = modeRevision
    return DictationOnlyMode.registersShortcut(slot, enabled: DictationOnlyMode.isEnabled)
  }

  /// Rows that had no shortcut when the section appeared. They sit behind "More shortcuts" and
  /// stay there for this visit, so a row does not jump out of the group the moment it is recorded.
  @State private var collapsedAtAppear: Set<SettingsFocusField>?
  @State private var showsMore = false

  /// One shortcut row's data. The binding is a `SettingsData` field, not the `ShortcutConfig` key path.
  private struct Entry {
    let label: LocalizedStringKey
    let binding: Binding<ShortcutDefinition?>
    let field: SettingsFocusField
  }

  /// Every row after Dictate, in menu order, filtered by build and "Dictation only".
  /// Literal keys, not `ShortcutAction.x.title`: interpolating the English `title` would leave the
  /// name untranslated.
  private var otherEntries: [Entry] {
    var entries: [Entry] = []
    if shows(.dictatePrompt) {
      entries.append(Entry(label: "Dictate Prompt", binding: $viewModel.data.togglePrompting, field: .togglePrompting))
    }
    if shows(.screenshot) {
      entries.append(Entry(label: "Screenshot", binding: $viewModel.data.screenshotCapture, field: .screenshotCapture))
    }
    // Selection-based shortcuts copy via ⌘C (Accessibility) — not in the App Store build.
    if ShortcutAction.readAloud.isInThisBuild && shows(.readAloud) {
      entries.append(Entry(label: "Read Aloud", binding: $viewModel.data.readAloud, field: .readAloudShortcut))
      entries.append(Entry(
        label: "Read Aloud Prompt", binding: $viewModel.data.readAloudPrompt, field: .readAloudPromptShortcut))
    }
    // Glossary is not a `ShortcutAction` (see that enum); Dictate Live pastes. Both: direct build only.
    #if !APP_STORE
    entries.append(Entry(label: "Add to Glossary", binding: $viewModel.data.addToGlossary, field: .addToGlossaryShortcut))
    entries.append(Entry(label: "Dictate Live", binding: $viewModel.data.liveDictate, field: .liveDictateShortcut))
    #endif
    if shows(.chat) {
      entries.append(Entry(label: "Open Chat", binding: $viewModel.data.openChat, field: .toggleChat))
    }
    entries.append(Entry(label: "Open Settings", binding: $viewModel.data.openSettings, field: .toggleSettings))
    return entries
  }

  private static func isSet(_ shortcut: ShortcutDefinition?) -> Bool {
    shortcut?.isEnabled == true
  }

  var body: some View {
    let entries = otherEntries
    let collapsed = collapsedAtAppear ?? Set(entries.filter { !Self.isSet($0.binding.wrappedValue) }.map(\.field))
    let visible = entries.filter { !collapsed.contains($0.field) }
    let hidden = entries.filter { collapsed.contains($0.field) }

    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Keyboard Shortcuts",
        systemImage: "keyboard",
        subtitle: "Work from any app. Press once to start, again to stop."
      )

      // Dictate is what almost everyone uses, so it leads, with its second trigger (🌐) right
      // under it instead of at the end of the list.
      row(Entry(label: "Dictate", binding: $viewModel.data.toggleDictation, field: .toggleDictation))
      #if !APP_STORE
      fnKeyToggle
        .padding(.leading, SettingsConstants.labelWidth + 16)
      #endif

      ForEach(visible, id: \.field) { row($0) }

      if !hidden.isEmpty {
        DisclosureGroup(isExpanded: $showsMore) {
          VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
            ForEach(hidden, id: \.field) { row($0) }
          }
          .padding(.top, 8)
        } label: {
          Text("More shortcuts")
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { showsMore.toggle() } }
        }
      }
    }
    .onAppear {
      collapsedAtAppear = Set(otherEntries.filter { !Self.isSet($0.binding.wrappedValue) }.map(\.field))
    }
    .onReceive(NotificationCenter.default.publisher(for: .dictationOnlyModeChanged)) { _ in
      modeRevision += 1
    }
  }

  private func row(_ entry: Entry) -> some View {
    ShortcutRecorderRow(
      label: entry.label,
      shortcut: entry.binding,
      focusedField: entry.field,
      currentFocus: $focusedField,
      onChanged: { Task { await viewModel.saveSettings() } },
      findConflict: viewModel.findShortcutConflict,
      clearShortcut: viewModel.clearShortcut
    )
  }

  #if !APP_STORE
  /// Second trigger for Dictate, directly under its row. On by default when the 🌐 key is free
  /// (`SettingsDefaults.fnKeyDictation`).
  ///
  /// The switch shows whether Fn *works*, not only the stored wish: on while Accessibility is
  /// missing was a switch that lied (UX review 2026-11-17). The wish (`fnKeyDictation`) is kept,
  /// so the switch turns on by itself once the permission arrives.
  private var fnKeyToggle: some View {
    let wantsFn = viewModel.data.fnKeyDictation
    return VStack(alignment: .leading, spacing: 6) {
      // The permission prompt lives in the binding's setter, not `onChange`: `onChange` also fires
      // when `data` is reloaded programmatically, which must never trigger a system prompt. The
      // setter only runs when the user flips this toggle.
      Toggle(isOn: Binding(
        get: { wantsFn && hasAccessibility },
        set: { newValue in
          DebugLogger.log("SHORTCUTS: Fn-key dictation toggled to \(newValue)")
          if newValue && !AccessibilityPermissionManager.hasAccessibilityPermission() {
            // Request now (native prompt + pre-registration), not deferred to the first fn press.
            AccessibilityPermissionManager.requestAccessibilityAtOptIn(for: .fnKey)
          }
          viewModel.data.fnKeyDictation = newValue
          Task { await viewModel.saveSettings() }
          refreshFnStatus()
        }
      )) {
        Text("Also start with 🌐 Fn")
          .font(.callout)
      }
      .toggleStyle(.switch)
      .controlSize(.small)

      if wantsFn && !hasAccessibility {
        HStack(spacing: 8) {
          Text("Needs Accessibility to notice the Fn key.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("Allow…") {
            AccessibilityPermissionManager.requestAccessibilityAtOptIn(for: .fnKey)
            refreshFnStatus()
          }
          .controlSize(.small)
          .pointerCursorOnHover()
        }
      }
      if wantsFn {
        GlobeKeyConflictCard()
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
    GlobeKeyStatus.shared.refresh()
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
