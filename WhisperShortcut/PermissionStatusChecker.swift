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
      // AX has no "notDetermined" state surfaced by the API.
      return AXIsProcessTrusted() ? .granted : .denied
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
      NSWorkspace.shared.open(url)
    } else {
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
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
}
