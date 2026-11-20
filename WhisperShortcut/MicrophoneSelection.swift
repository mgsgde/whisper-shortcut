//
//  MicrophoneSelection.swift
//  WhisperShortcut
//
//  The persisted microphone choice (a CoreAudio device UID) and how a recording
//  resolves it. Absent, empty, or not currently connected all mean: keep using
//  the macOS default input, which is what the recorders already did.
//

import Foundation

enum MicrophoneSelection {

  enum Resolution: Equatable {
    /// Nothing chosen. Recording stays on the macOS default input.
    case systemDefault
    /// Chosen, and that device is connected right now.
    case device(AudioInputDeviceCatalog.InputDevice)
    /// Chosen, but not in the connected-microphone list. Callers record from the default.
    case missing(uid: String)
  }

  /// Pure, unit-tested. An empty UID is the same as no choice.
  static func resolve(
    selectedUID: String?, available: [AudioInputDeviceCatalog.InputDevice]
  ) -> Resolution {
    guard let selectedUID, selectedUID.isEmpty == false else { return .systemDefault }
    if let device = available.first(where: { $0.uid == selectedUID }) {
      return .device(device)
    }
    return .missing(uid: selectedUID)
  }

  /// CoreAudio UID stored in `UserDefaults`. An empty string is read back as nil,
  /// and setting nil (or "") removes the key so the default stays "not chosen".
  static var selectedUID: String? {
    get {
      guard let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedMicrophoneUID),
        stored.isEmpty == false
      else { return nil }
      return stored
    }
    set {
      if let newValue, newValue.isEmpty == false {
        UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.selectedMicrophoneUID)
      } else {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedMicrophoneUID)
      }
    }
  }

  static func current() -> Resolution {
    resolve(selectedUID: selectedUID, available: AudioInputDeviceCatalog.availableDevices())
  }

  /// Name for the recording pill: the chosen device when it is connected, otherwise
  /// the macOS default input. nil when CoreAudio has no usable answer.
  static func activeInputDeviceName() -> String? {
    switch current() {
    case .device(let device):
      return device.name
    case .systemDefault, .missing:
      return AudioInputDeviceCatalog.defaultInputDeviceName()
    }
  }

  /// Once per recording start when the choice is `.missing`, and again if the chosen
  /// device disappears mid-recording. The popup is the same text either way, and it
  /// is shown at most once per 10 minutes.
  static func noteFallback(uid: String) {
    let deliver = { deliverFallbackNote(uid: uid) }
    if Thread.isMainThread {
      deliver()
    } else {
      DispatchQueue.main.async(execute: deliver)
    }
  }

  private static let fallbackNoteInterval: TimeInterval = 10 * 60
  /// Touched only on the main thread.
  private static var lastFallbackNoteAt: Date?

  private static func deliverFallbackNote(uid: String) {
    let now = Date()
    if let lastFallbackNoteAt, now.timeIntervalSince(lastFallbackNoteAt) < fallbackNoteInterval {
      return
    }
    lastFallbackNoteAt = now
    DebugLogger.logAudio("AUDIO: Noting microphone fallback for \(uid)")
    PopupNotificationWindow.showInfo(
      "The selected microphone is not connected. Recording with the system default instead.",
      title: "Microphone")
  }
}
