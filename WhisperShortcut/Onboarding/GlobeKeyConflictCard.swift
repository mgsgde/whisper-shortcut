import AppKit
import SwiftUI

/// Shown wherever Fn dictation is on (onboarding permissions step, Settings → Keyboard
/// Shortcuts). While macOS still reacts to the 🌐 key itself it is a one-line `SettingsCallout`
/// naming what Fn does instead, with the one-click fix on its trailing edge (the button's tooltip
/// spells out the exact system setting it changes); once the key is Do Nothing it shrinks to a
/// green check line. Renders nothing when there never was a conflict.
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
    VStack(alignment: .leading, spacing: 6) {
      SettingsCallout(
        symbol: "globe",
        title: "Fn still opens “\(systemAction)”",
        detail: conflictDetail
      ) {
        #if !APP_STORE
          Button("Free Key", action: freeKey)
            .buttonStyle(.borderedProminent)
            .help("Sets System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”. You can change it back there at any time.")
            .pointerCursorOnHover()
          Button {
            GlobeKeyUsage.openKeyboardSettings()
          } label: {
            Image(systemName: "gearshape")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Open Keyboard Settings")
          .pointerCursorOnHover()
        #else
          Button("Open Keyboard Settings") {
            GlobeKeyUsage.openKeyboardSettings()
          }
          .buttonStyle(.borderedProminent)
          .pointerCursorOnHover()
        #endif
      }

      if let onTurnOffFn {
        Button(action: onTurnOffFn) {
          Text(turnOffFnTitle)
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.leading, 46)
        .pointerCursorOnHover()
      }
    }
  }

  private var conflictDetail: LocalizedStringKey {
    if freeFailed {
      return "macOS didn’t accept it. Choose “Do Nothing” next to “Press 🌐 key to” in Keyboard settings."
    }
    #if APP_STORE
      return "In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”."
    #else
      return "Free the 🌐 key once, then Fn dictates."
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
    SettingsConfirmation(text: "The 🌐 key is free. Fn starts and stops dictation.")
  }
}
