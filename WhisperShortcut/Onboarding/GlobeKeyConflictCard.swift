import AppKit
import SwiftUI

/// Shown wherever Fn dictation is on (onboarding permissions step, Settings → Keyboard
/// Shortcuts). While macOS still reacts to the 🌐 key itself it is an orange warning that says
/// what happens, why Fn dictation cannot work yet and what to do; once the key is Do Nothing it
/// turns into a green confirmation. Renders nothing when there never was a conflict.
///
/// It replaces a one-line grey caption that a pilot user overlooked on 2026-11-02: she pressed
/// Fn, the emoji picker opened, and nothing told her why dictation did not start.
struct GlobeKeyConflictCard: View {
  /// Onboarding passes this so the card can offer "turn Fn off, use the shortcut" — the second
  /// way past the step besides freeing the key. Settings has the Fn toggle right above and
  /// passes nil.
  var onTurnOffFn: (() -> Void)?

  @ObservedObject private var status = GlobeKeyStatus.shared
  /// Set once this card has shown a conflict, so the green confirmation appears only for a
  /// conflict the user just resolved — not for everyone whose key was free all along.
  @State private var sawConflict = false
  @State private var confirmingFree = false
  /// The write did not stick (sandbox refused, or macOS ignored it); Keyboard settings were opened.
  @State private var freeFailed = false

  var body: some View {
    Group {
      if let systemAction = status.usage.systemSettingsLabel {
        conflictCard(systemAction: systemAction)
      } else if sawConflict && status.usage == .doNothing {
        resolvedCard
      }
    }
    .onAppear {
      status.refresh()
      if status.usage.conflictsWithFnDictation { sawConflict = true }
    }
    .onChange(of: status.usage) { _, usage in
      if usage.conflictsWithFnDictation { sawConflict = true }
      if usage == .doNothing { freeFailed = false }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      status.refresh()
    }
  }

  // MARK: - Conflict

  private func conflictCard(systemAction: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text("Fn dictation won’t work yet")
          .font(.callout)
          .fontWeight(.semibold)
      }

      Text("When you press 🌐 Fn, macOS currently does “\(systemAction)” instead, so your dictation does not start. To fix this, set “Press 🌐 key to” to “Do Nothing” — once, and Fn dictates from then on.")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)

      if freeFailed {
        Text("macOS did not accept the change. Keyboard settings are open: choose “Do Nothing” next to “Press 🌐 key to”, then come back here.")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        #if !APP_STORE
          Button {
            confirmingFree = true
          } label: {
            Text("Free the 🌐 key for WhisperShortcut")
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
          .pointerCursorOnHover()
        #endif
        Button("Open Keyboard Settings") {
          GlobeKeyUsage.openKeyboardSettings()
        }
        .buttonStyle(.bordered)
        .pointerCursorOnHover()
      }

      if let onTurnOffFn {
        Button(action: onTurnOffFn) {
          Text(turnOffFnTitle)
        }
        .buttonStyle(.link)
        .font(.caption)
        .pointerCursorOnHover()
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardChrome(fill: Color.orange.opacity(0.12), stroke: Color.orange.opacity(0.6))
    #if !APP_STORE
      .alert("Free the 🌐 key?", isPresented: $confirmingFree) {
        Button("Free the Key", action: freeKey)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("WhisperShortcut will change one macOS setting: System Settings → Keyboard → “Press 🌐 key to” becomes “Do Nothing”. Pressing 🌐 Fn then only starts and stops your dictation. You can change it back there at any time.")
      }
    #endif
  }

  /// "Use ⌥⌘D instead" names the shortcut she will actually press; without an enabled Dictate
  /// shortcut there is nothing to name.
  private var turnOffFnTitle: LocalizedStringKey {
    let shortcut = ShortcutConfigManager.shared.loadConfiguration()[keyPath: ShortcutAction.dictate.keyPath]
    guard shortcut.isEnabled else { return "Turn off Fn dictation instead" }
    return "Turn off Fn dictation and use \(shortcut.displayString) instead"
  }

  #if !APP_STORE
    private func freeKey() {
      if GlobeKeyUsage.freeForFnDictation() {
        DebugLogger.log("GLOBE-KEY: freed the 🌐 key from the conflict card")
        freeFailed = false
      } else {
        DebugLogger.logWarning("GLOBE-KEY: write did not stick — opening Keyboard settings instead")
        freeFailed = true
        GlobeKeyUsage.openKeyboardSettings()
      }
      status.refresh()
    }
  #endif

  // MARK: - Resolved

  private var resolvedCard: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
      Text("The 🌐 key is free. Press Fn once to start dictating, again to stop.")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardChrome(fill: Color.green.opacity(0.12), stroke: Color.green.opacity(0.6))
  }
}
