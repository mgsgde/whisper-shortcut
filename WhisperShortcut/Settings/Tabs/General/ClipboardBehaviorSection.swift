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
        Text("Restore clipboard:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: $viewModel.data.restoreClipboardAfterPaste)
          .toggleStyle(SwitchToggleStyle())
          .accessibilityLabel("Restore clipboard after auto-paste")
          .disabled(!viewModel.data.autoPasteAfterDictation)
          .onChange(of: viewModel.data.restoreClipboardAfterPaste) { _, newValue in
            DebugLogger.log("AUTO-PASTE SETTINGS: Restore clipboard changed to \(newValue)")
            Task {
              await viewModel.saveSettings()
            }
          }

        Spacer()
      }

      Text("Puts back what you had copied before, right after pasting. Needs auto-paste.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      #endif
    }
  }
}
