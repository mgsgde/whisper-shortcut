//
//  MeetingAudioMode.swift
//  WhisperShortcut
//
//  Whether a Live Meeting recording expects an online meeting (other participants heard
//  through speakers, so system audio is mixed in) or an in-person one (no system audio).
//

import Foundation

enum MeetingAudioMode: String, CaseIterable {
  case online
  case inPerson

  /// Persisted mode. Unset or an unknown stored raw value both read as `.inPerson`, so an
  /// install that predates this setting keeps recording exactly as before.
  static var current: MeetingAudioMode {
    get {
      guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.liveMeetingAudioMode),
        let mode = MeetingAudioMode(rawValue: raw)
      else {
        return .inPerson
      }
      return mode
    }
    set {
      let changed = current != newValue
      UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaultsKeys.liveMeetingAudioMode)
      if changed {
        NotificationCenter.default.post(name: .liveMeetingAudioModeChanged, object: nil)
      }
    }
  }
}

extension Notification.Name {
  static let liveMeetingAudioModeChanged = Notification.Name("liveMeetingAudioModeChanged")
}
