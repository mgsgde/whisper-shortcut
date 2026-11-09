import AppKit
import Foundation

/// What macOS does with the 🌐 key (`AppleFnUsageType` in `com.apple.HIToolbox`).
///
/// Fn dictation can be on by default only when that setting is Do Nothing. Otherwise one Fn
/// press would also open the emoji picker, switch the input source, or start Apple Dictation.
/// The app is sandboxed, so touching another app's preference domain needs the shared-preference
/// exception for `com.apple.HIToolbox` in `WhisperShortcut.entitlements` (read-write since the
/// onboarding can free the key on request; the App Store entitlements have no exception at all).
/// Without it `CFPreferencesCopyAppValue` returns nil and this reports `.unknown`, which keeps
/// the default off.
enum GlobeKeyUsage: Equatable {
  /// AppleFnUsageType 0 — "Do Nothing". The key is free for this app.
  case doNothing
  /// AppleFnUsageType 1 — "Change Input Source".
  case changeInputSource
  /// AppleFnUsageType 2 — "Show Emoji & Symbols".
  case emojiAndSymbols
  /// AppleFnUsageType 3 — "Start Dictation".
  case startDictation
  /// Missing key, or a value this app does not know. Treated as not free so a future macOS
  /// value is not mistaken for Do Nothing.
  case unknown

  /// The setting on this Mac. The App Store build never reads another process's preferences;
  /// Fn dictation is off there regardless.
  static var current: GlobeKeyUsage {
    #if APP_STORE
      return .unknown
    #else
      let raw = CFPreferencesCopyAppValue(
        "AppleFnUsageType" as CFString,
        "com.apple.HIToolbox" as CFString
      ) as? NSNumber
      return usage(fromRawValue: raw?.intValue)
    #endif
  }

  /// True when a Fn press does nothing of Apple's, so turning Fn dictation on cannot also
  /// trigger a system action.
  static var isFree: Bool { current == .doNothing }

  /// The matching item under System Settings → Keyboard → "Press 🌐 key to", in the wording
  /// macOS shows in the user's language. Nil when there is nothing to ask the user to change.
  var systemSettingsLabel: String? {
    switch self {
    case .doNothing, .unknown:
      return nil
    case .changeInputSource:
      return String(localized: "Change Input Source")
    case .emojiAndSymbols:
      return String(localized: "Show Emoji & Symbols")
    case .startDictation:
      return String(localized: "Start Dictation")
    }
  }

  /// True when macOS itself reacts to the 🌐 key, so a Fn press would do two things at once.
  /// `.unknown` is not a conflict: it cannot be resolved from here (a read the sandbox refused, or
  /// a future macOS value), and blocking on it would leave the user stuck.
  var conflictsWithFnDictation: Bool { systemSettingsLabel != nil }

  /// Whether the onboarding step with the Fn toggle may continue. With Fn on and a known conflict,
  /// Fn dictation would silently do nothing (the emoji picker opens instead), which is exactly how
  /// a pilot user got stuck on 2026-11-02. She has two ways out: free the key, or turn Fn off and
  /// use the keyboard shortcut.
  static func fnSetupMayContinue(fnEnabled: Bool, usage: GlobeKeyUsage) -> Bool {
    !fnEnabled || !usage.conflictsWithFnDictation
  }

  #if !APP_STORE
    /// Sets "Press 🌐 key to" to Do Nothing. Only ever called after the user confirmed that exact
    /// change. Returns whether a fresh read shows Do Nothing; on false the caller falls back to
    /// opening Keyboard settings.
    ///
    /// It calls Apple's own setter `TISUpdateFnUsageType` (the one System Settings' Keyboard pane
    /// uses), resolved at runtime because it is a private symbol. It writes `AppleFnUsageType`
    /// and is what the system reacts to. Raw CFPreferences is only the fallback if the symbol
    /// disappears in a future macOS. Live effect is still to be confirmed on a Mac set to
    /// "Show Emoji & Symbols": press Fn in TextEdit after freeing; the emoji picker must not open.
    static func freeForFnDictation() -> Bool {
      var path = "CFPreferences"
      // RTLD_DEFAULT is (void *)-2.
      if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "TISUpdateFnUsageType") {
        let setter = unsafeBitCast(sym, to: (@convention(c) (Int32) -> Void).self)
        setter(0)
        path = "TIS"
      } else {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesSetAppValue("AppleFnUsageType" as CFString, NSNumber(value: 0), domain)
        CFPreferencesAppSynchronize(domain)
      }
      let after = current
      DebugLogger.log("GLOBE-KEY: set AppleFnUsageType=0 via \(path); re-read \(after)")
      return after == .doNothing
    }
  #endif

  /// Opens System Settings on the Keyboard pane, where "Press 🌐 key to" lives.
  static func openKeyboardSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
      return
    }
    Task { @MainActor in SystemSettingsOpener.open(url) }
  }

  /// Maps Apple's `AppleFnUsageType` integer. Anything else, including a missing value, is
  /// `.unknown` so it is not treated as Do Nothing.
  static func usage(fromRawValue: Int?) -> GlobeKeyUsage {
    switch fromRawValue {
    case 0: return .doNothing
    case 1: return .changeInputSource
    case 2: return .emojiAndSymbols
    case 3: return .startDictation
    default: return .unknown
    }
  }
}

/// The 🌐 setting as one shared, observable value, so the onboarding footer (Continue), the
/// warning card and Settings all flip together after the user frees the key — whether that
/// happened through the in-app button or in System Settings (callers refresh on
/// `didBecomeActiveNotification`).
@MainActor
final class GlobeKeyStatus: ObservableObject {
  static let shared = GlobeKeyStatus()

  @Published private(set) var usage: GlobeKeyUsage = .current

  private init() {}

  func refresh() {
    let now = GlobeKeyUsage.current
    if now != usage { usage = now }
  }
}
