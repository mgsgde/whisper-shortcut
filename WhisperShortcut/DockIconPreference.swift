import AppKit
import Foundation

/// Optional Dock icon for a menu-bar app.
///
/// `Info.plist` declares `LSUIElement = true`, so the app normally has no Dock icon and cannot be
/// reached with ⌘-Tab. Some users want exactly that, so the activation policy is switched at
/// runtime instead of shipping a second build: `.regular` shows the Dock icon, `.accessory` (the
/// `LSUIElement` behaviour) hides it again.
///
/// The policy is not persisted by macOS — it has to be applied on every launch, which is why
/// `apply()` runs from `applicationDidFinishLaunching` as well as from the Settings toggle.
enum DockIconPreference {
  /// The stored choice, falling back to `SettingsDefaults.showDockIcon` when nothing is stored.
  static var isEnabled: Bool {
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.showDockIcon) != nil {
      return UserDefaults.standard.bool(forKey: UserDefaultsKeys.showDockIcon)
    }
    return SettingsDefaults.showDockIcon
  }

  /// Applies the stored choice to the running app. Safe to call repeatedly.
  ///
  /// `.regular` does not make the app quit when its last window closes —
  /// `applicationShouldTerminateAfterLastWindowClosed` returns `false` (FullApp.swift), so the
  /// menu-bar item and the background work survive.
  @MainActor
  static func apply() {
    let enabled = isEnabled
    NSApp.setActivationPolicy(enabled ? .regular : .accessory)
    DebugLogger.log("DOCK-ICON: activation policy → \(enabled ? "regular (Dock icon shown)" : "accessory (menu bar only)")")
  }
}
