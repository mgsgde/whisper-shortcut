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
        title: "Clipboard Behavior",
        systemImage: "doc.on.clipboard",
        subtitle: "What happens when Dictate or Dictate Prompt is done."
      )

      #if APP_STORE
      // Auto-paste synthesizes ⌘V, which needs the Accessibility permission Apple rejects for
      // App Store builds (Guideline 2.4.5). Explain the gap instead of hiding the section, so
      // users don't conclude the feature doesn't exist at all.
      Text("Auto-paste — inserting dictated text right at your cursor — isn't available in the Mac App Store version, because it requires a system permission that isn't allowed for App Store apps. Your text is always copied to the clipboard, so you can paste it with ⌘V. The direct-download version from whispershortcut.com supports auto-paste.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Link("Get the direct-download version", destination: URL(string: "https://whispershortcut.com")!)
        .font(.callout)
        .pointerCursorOnHover()
      #else
      HStack(alignment: .center, spacing: 16) {
        Text("Auto-paste:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        // The permission prompt lives in the binding's setter, not `onChange`: `onChange` also
        // fires when `data` is reloaded programmatically (e.g. `settingsChangedExternally`),
        // which must never trigger a system prompt. The setter only runs when the user flips
        // this toggle.
        Toggle("", isOn: Binding(
          get: { viewModel.data.autoPasteAfterDictation },
          set: { newValue in
            DebugLogger.log("AUTO-PASTE SETTINGS: Toggle changed to \(newValue), hasAccessibility=\(AccessibilityPermissionManager.hasAccessibilityPermission())")
            if newValue && !AccessibilityPermissionManager.hasAccessibilityPermission() {
              DebugLogger.log("AUTO-PASTE SETTINGS: Requesting Accessibility at opt-in")
              // Request now (native prompt + pre-registration), not deferred to first auto-paste.
              AccessibilityPermissionManager.requestAccessibilityAtOptIn()
            }
            viewModel.data.autoPasteAfterDictation = newValue
            Task {
              await viewModel.saveSettings()
            }
          }
        ))
          .toggleStyle(SwitchToggleStyle())
          .accessibilityLabel("Auto-paste")

        Spacer()
      }

      Text("Pastes the result at the cursor (⌘V). Needs Accessibility permission.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(alignment: .center, spacing: 16) {
        Text("After auto-paste:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        // One choice instead of two toggles: restore and clear contradict each other, and two
        // switches let both look on at once (pilot feedback 2026-11-03). Stored in the existing
        // two keys, so no migration.
        Picker("", selection: afterPasteBinding) {
          ForEach(AfterPasteClipboard.allCases, id: \.self) { option in
            Text(option.displayName).tag(option)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .accessibilityLabel("Clipboard after auto-paste")
        .disabled(!viewModel.data.autoPasteAfterDictation)

        Spacer()
      }

      Text(afterPasteBinding.wrappedValue.explanation)
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      #endif
    }
  }

  private var afterPasteBinding: Binding<AfterPasteClipboard> {
    Binding(
      get: {
        if viewModel.data.restoreClipboardAfterPaste { return .restore }
        if viewModel.data.clearClipboardAfterAutoPaste { return .clear }
        return .keep
      },
      set: { option in
        DebugLogger.log("AUTO-PASTE SETTINGS: Clipboard after paste changed to \(option)")
        viewModel.data.restoreClipboardAfterPaste = option == .restore
        viewModel.data.clearClipboardAfterAutoPaste = option == .clear
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }
}

private enum AfterPasteClipboard: CaseIterable {
  case keep, restore, clear

  var displayName: String {
    switch self {
    case .keep: return String(localized: "Leave dictation")
    case .restore: return String(localized: "Restore previous")
    case .clear: return String(localized: "Empty it")
    }
  }

  var explanation: String {
    switch self {
    case .keep:
      return String(localized: "The dictated text stays on the clipboard, so you can paste it again with ⌘V.")
    case .restore:
      return String(localized: "Puts back what you had copied before, right after pasting.")
    case .clear:
      return String(localized: "Empties the clipboard after pasting, so a later ⌘V cannot paste an earlier dictation. Copy Last Transcription still works.")
    }
  }
}
