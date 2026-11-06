import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// Coarse-grained status for an OS-level permission.
/// `notApplicable` is reserved for callers that want to surface non-OS gates
/// (e.g. API keys) through the same UI shape — the checker itself never returns it.
enum PermissionStatus {
  case granted
  case denied
  case notDetermined
  case notApplicable
}

/// OS permissions surfaced in the Privacy & Permissions tab.
enum PermissionKind {
  case microphone
  case accessibility
  case screenRecording
}

/// Dependency-free, read-only inspector for the macOS permissions WhisperShortcut uses.
/// Does NOT trigger any TCC prompt by itself (callers do that through the existing
/// permission request paths in AudioRecorder / AccessibilityPermissionManager).
enum PermissionStatusChecker {

  static func status(for kind: PermissionKind) -> PermissionStatus {
    switch kind {
    case .microphone:
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized:
        return .granted
      case .denied, .restricted:
        return .denied
      case .notDetermined:
        return .notDetermined
      @unknown default:
        return .notDetermined
      }
    case .accessibility:
      // AX has no "notDetermined" state surfaced by the API. Approximate it with "has this
      // app ever fired the AX prompt": a fresh install then shows "Not requested" instead of
      // a red "Denied" for something the user was never asked about.
      if AXIsProcessTrusted() { return .granted }
      return UserDefaults.standard.bool(forKey: UserDefaultsKeys.hasShownAccessibilityPrompt)
        ? .denied : .notDetermined
    case .screenRecording:
      // CGPreflightScreenCaptureAccess() doesn't disambiguate denied vs. not-yet-requested.
      // Map "true" to granted and "false" to notDetermined so the UI shows an actionable
      // "Open System Settings" affordance without falsely accusing the user of denying.
      return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }
  }

  /// Opens the relevant System Settings pane via the documented x-apple.systempreferences
  /// URL scheme (same approach AccessibilityPermissionManager uses for AX).
  static func openSystemSettings(for kind: PermissionKind) {
    let urlString: String
    switch kind {
    case .microphone:
      urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case .accessibility:
      urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case .screenRecording:
      urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    }
    if let url = URL(string: urlString) {
      Task { @MainActor in SystemSettingsOpener.open(url) }
    } else {
      let fallback = URL(fileURLWithPath: "/System/Applications/System Settings.app")
      Task { @MainActor in SystemSettingsOpener.open(fallback) }
    }
  }

  /// Requests microphone access via AVCaptureDevice. This is the ONLY permission with a
  /// programmatic prompt path the Privacy tab exposes directly — AX and Screen Recording
  /// must be granted in System Settings.
  static func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      DispatchQueue.main.async {
        completion(granted)
      }
    }
  }

  /// Triggers the native macOS Screen Recording consent prompt the first time it's called
  /// (when status is not-yet-determined). Once denied, macOS no longer prompts and the user
  /// must enable access in System Settings — callers should offer that as a fallback.
  @discardableResult
  static func requestScreenRecordingAccess() -> Bool {
    return CGRequestScreenCaptureAccess()
  }

  /// Triggers the native macOS Accessibility consent prompt via the `kAXTrustedCheckOptionPrompt`
  /// option. Beyond prompting, this is the ONLY way to make macOS pre-register WhisperShortcut in
  /// the Accessibility list in System Settings (greyed-out), so the user only has to flip the
  /// switch instead of manually adding the app with "+". Returns the *current* trust state, which
  /// is almost always `false` on the first call because granting happens asynchronously in
  /// System Settings. Like Screen Recording, macOS suppresses the prompt after a prior denial —
  /// callers should fall back to deep-linking into System Settings in that case.
  @discardableResult
  static func requestAccessibilityAccess() -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Fires the native permission request before deep-linking into Privacy & Security. Call on the
  /// main thread.
  ///
  /// macOS lists an app under Microphone, Accessibility, or Screen Recording only after that app
  /// has called the native request API once. A button that only opens the pane lands on a list
  /// without WhisperShortcut, and the user has to add it manually with "+". The request
  /// pre-registers the app so the switch is already there.
  ///
  /// Microphone requests only while the status is `.notDetermined`, and opens Settings when that
  /// request is denied; any other status opens Settings immediately. Screen Recording opens
  /// Settings when already granted; otherwise it requests access and, if that does not grant it,
  /// opens Settings after 0.5 s when the status is still not granted. Accessibility calls
  /// `AccessibilityPermissionManager.requestThenOpenAccessibilitySettings()`, which reads the prompt
  /// flag, calls `requestAccessibilityPermission()` (re-registers the entry even after a `tccutil`
  /// reset), and opens Settings only when a prompt was already shown and access is still not
  /// trusted. The first native prompt has its own Open System Settings button, so this does not
  /// open the pane a second time.
  static func requestThenOpenSystemSettings(for kind: PermissionKind) {
    switch kind {
    case .microphone:
      if status(for: .microphone) == .notDetermined {
        requestMicrophoneAccess { granted in
          if !granted {
            openSystemSettings(for: .microphone)
          }
        }
      } else {
        openSystemSettings(for: .microphone)
      }
    case .screenRecording:
      if status(for: .screenRecording) == .granted {
        openSystemSettings(for: .screenRecording)
      } else {
        let granted = requestScreenRecordingAccess()
        if !granted {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if status(for: .screenRecording) != .granted {
              openSystemSettings(for: .screenRecording)
            }
          }
        }
      }
    case .accessibility:
      AccessibilityPermissionManager.requestThenOpenAccessibilitySettings()
    }
  }
}
