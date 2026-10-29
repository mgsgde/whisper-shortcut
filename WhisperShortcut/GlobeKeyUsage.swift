import AppKit
import Foundation

/// What macOS does with the 🌐 key (`AppleFnUsageType` in `com.apple.HIToolbox`).
///
/// Fn dictation can be on by default only when that setting is Do Nothing. Otherwise one Fn
/// press would also open the emoji picker, switch the input source, or start Apple Dictation.
/// The app is sandboxed, so reading another app's preference domain needs the read-only
/// shared-preference exception for `com.apple.HIToolbox` in `WhisperShortcut.entitlements`.
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

  /// The matching item under System Settings → Keyboard → "Press 🌐 key to". Nil when there
  /// is nothing to ask the user to change.
  var systemSettingsLabel: String? {
    switch self {
    case .doNothing, .unknown:
      return nil
    case .changeInputSource:
      return "Change Input Source"
    case .emojiAndSymbols:
      return "Show Emoji & Symbols"
    case .startDictation:
      return "Start Dictation"
    }
  }

  /// Opens System Settings on the Keyboard pane, where "Press 🌐 key to" lives.
  static func openKeyboardSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
      return
    }
    NSWorkspace.shared.open(url)
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
