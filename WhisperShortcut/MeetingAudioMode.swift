//
//  MeetingAudioMode.swift
//  WhisperShortcut
//
//  How a Live Meeting records the other participants. The preference is what the user chose
//  (automatic, always mix the Mac's sound, or microphone only). The routing is what the running
//  meeting actually does, once Automatic is combined with the Mac's output device: headphones
//  mix system audio in, because the microphone cannot hear the other side; speakers stay
//  microphone-only, because mixing would record them twice.
//

import Foundation

enum MeetingAudioPreference: String, CaseIterable {
  case automatic
  case alwaysMixSystemAudio
  case microphoneOnly

  /// Key `UserDefaultsKeys.liveMeetingAudioPreference`. Unset or an unknown raw value reads as
  /// `.automatic`. The setter persists and posts `.liveMeetingAudioPreferenceChanged` only when
  /// the value changed.
  static var current: MeetingAudioPreference {
    get { load(.standard) }
    set {
      let changed = load(.standard) != newValue
      UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaultsKeys.liveMeetingAudioPreference)
      if changed {
        NotificationCenter.default.post(name: .liveMeetingAudioPreferenceChanged, object: nil)
      }
    }
  }

  static func load(_ defaults: UserDefaults) -> MeetingAudioPreference {
    guard let raw = defaults.string(forKey: UserDefaultsKeys.liveMeetingAudioPreference),
      let preference = MeetingAudioPreference(rawValue: raw)
    else {
      return .automatic
    }
    return preference
  }

  /// One-time migration of the old switch (`UserDefaultsKeys.liveMeetingAudioMode`, values
  /// "online"/"inPerson"): every old value becomes `.automatic` (old "online" was only ever the
  /// way to get system audio, which Automatic now gives on headphones; on speakers mixing would
  /// record the other side twice). Removes the old key. Writes nothing new. Idempotent.
  static func migrateLegacyAudioMode(_ defaults: UserDefaults = .standard) {
    guard defaults.object(forKey: UserDefaultsKeys.liveMeetingAudioMode) != nil else { return }
    defaults.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
  }
}

/// What the running meeting actually records, derived from preference + output route.
enum MeetingAudioRouting: Equatable, CustomStringConvertible {
  /// Automatic, and the output is not a speaker: mix system audio.
  case headphones
  /// Automatic, and the output is a speaker: microphone only.
  case speakers
  /// Automatic, and there is no output device: microphone only.
  case noOutputDevice
  /// Preference `.alwaysMixSystemAudio`.
  case manualMix
  /// Preference `.microphoneOnly`.
  case manualMicrophoneOnly

  var mixesSystemAudio: Bool {
    switch self {
    case .headphones, .manualMix: return true
    case .speakers, .noOutputDevice, .manualMicrophoneOnly: return false
    }
  }

  var isManual: Bool {
    switch self {
    case .manualMix, .manualMicrophoneOnly: return true
    case .headphones, .speakers, .noOutputDevice: return false
    }
  }

  var description: String {
    switch self {
    case .headphones: return "headphones"
    case .speakers: return "speakers"
    case .noOutputDevice: return "noOutputDevice"
    case .manualMix: return "manualMix"
    case .manualMicrophoneOnly: return "manualMicrophoneOnly"
    }
  }

  /// Speaker (`OutputRoute.isLikelySpeaker`) → `.speakers`, anything else with a device →
  /// `.headphones`. A missing route stays microphone-only.
  static func resolve(preference: MeetingAudioPreference, route: OutputRoute?) -> MeetingAudioRouting {
    switch preference {
    case .alwaysMixSystemAudio:
      return .manualMix
    case .microphoneOnly:
      return .manualMicrophoneOnly
    case .automatic:
      guard let route else { return .noOutputDevice }
      return route.isLikelySpeaker ? .speakers : .headphones
    }
  }
}

extension Notification.Name {
  static let liveMeetingAudioPreferenceChanged = Notification.Name(
    "liveMeetingAudioPreferenceChanged")
}
