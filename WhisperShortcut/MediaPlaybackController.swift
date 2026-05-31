//
//  MediaPlaybackController.swift
//  WhisperShortcut
//
//  Pauses whatever media is currently playing (Music, Spotify, a browser video, …)
//  while a recording is in progress and resumes it afterward, so background audio
//  doesn't bleed into the dictation.
//
//  Implementation: we emit the hardware "play/pause" media key (NX_KEYTYPE_PLAY)
//  as a synthetic system-defined event — the same key the keyboard's ▶︎❙❙ button
//  sends. macOS routes it to the system "Now Playing" app. This is deliberately
//  app-agnostic so it works with any media source, not just one hard-coded player.
//
//  Caveats this design accepts:
//  • The media key is a *toggle*, not separate pause/play commands, and there is no
//    sandbox-safe way to read the current play state. We therefore pause on start and
//    toggle again on stop. When something is playing this pauses → resumes correctly.
//    If *nothing* is playing when recording starts, the toggle may instead *start*
//    playback for the duration of the recording. That's why this is opt-in (off by
//    default) and surfaced with a clear description in Settings.
//  • Posting synthetic events requires Accessibility permission (same as auto-paste).
//    Without it we silently no-op rather than nagging the user for an optional nicety.
//
//  Real-time communication apps (Teams, Zoom, Meet, FaceTime) are not "Now Playing"
//  media sessions, so the play/pause key does not pause or otherwise disrupt an active
//  call — at most it pauses background music you had running alongside the call.
//

import AppKit

final class MediaPlaybackController {
  /// True between a successful pause and its matching resume, so we only ever resume
  /// playback we ourselves paused (and only once per recording).
  private var didPauseForRecording = false

  /// NX_KEYTYPE_PLAY from <IOKit/hidsystem/ev_keymap.h>; not bridged to Swift.
  private static let playPauseKeyCode = 16

  /// Pauses current media playback if the feature is enabled and Accessibility is granted.
  func pauseForRecordingIfEnabled() {
    let enabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.pauseMediaDuringRecording) != nil
      ? UserDefaults.standard.bool(forKey: UserDefaultsKeys.pauseMediaDuringRecording)
      : SettingsDefaults.pauseMediaDuringRecording
    guard enabled else { return }

    guard AccessibilityPermissionManager.hasAccessibilityPermission() else {
      DebugLogger.logWarning("MEDIA-PAUSE: Skipped — Accessibility permission not granted")
      return
    }

    Self.sendPlayPauseKey()
    didPauseForRecording = true
    DebugLogger.log("MEDIA-PAUSE: Sent play/pause to pause media for recording")
  }

  /// Resumes media playback only if we paused it for this recording. Idempotent: safe to
  /// call from every stop/cleanup path; it fires the resume toggle at most once.
  func resumeAfterRecordingIfNeeded() {
    guard didPauseForRecording else { return }
    didPauseForRecording = false
    Self.sendPlayPauseKey()
    DebugLogger.log("MEDIA-PAUSE: Sent play/pause to resume media after recording")
  }

  /// Emits a single system-wide play/pause media-key press (key down + up).
  private static func sendPlayPauseKey() {
    postKey(down: true)
    postKey(down: false)
  }

  private static func postKey(down: Bool) {
    // Encoding per the documented NSSystemDefined media-key convention: data1's high
    // word is the key code, the low word carries the key state (0xA = down, 0xB = up).
    let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0xA00 : 0xB00))
    let data1 = (playPauseKeyCode << 16) | ((down ? 0xA : 0xB) << 8)

    guard
      let event = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: data1,
        data2: -1)
    else { return }

    event.cgEvent?.post(tap: .cghidEventTap)
  }
}
