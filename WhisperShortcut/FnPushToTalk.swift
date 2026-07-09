import AppKit
import Carbon.HIToolbox
import Foundation

protocol FnPushToTalkDelegate: AnyObject {
  /// Attempt to start a Dictate recording. Returns true only if a recording actually started.
  func fnPushToTalkStart() -> Bool
  /// Stop the recording and transcribe (normal stop path, including tail capture).
  func fnPushToTalkFinish()
  /// Stop the recording and drop the audio (accidental tap / fn used as a modifier).
  func fnPushToTalkDiscard()
}

/// Hold the Fn (Globe) key to dictate: fn-down starts a Dictate recording, releasing the key
/// stops and transcribes it. Opt-in via Settings → Dictate.
///
/// Fn is a modifier, not a regular key, so it can't be a Carbon hotkey like the other
/// shortcuts — it's observed through NSEvent flagsChanged monitors instead. Global monitors
/// only deliver key events when the app is trusted for Accessibility, the same permission
/// story as auto-paste, which is why the feature is absent from the App Store build.
final class FnPushToTalk {
  weak var delegate: FnPushToTalkDelegate?

  private var globalFlagsMonitor: Any?
  private var localFlagsMonitor: Any?
  private var globalKeyDownMonitor: Any?
  private var localKeyDownMonitor: Any?
  /// Non-nil while an fn-initiated recording is running; value is when fn went down.
  private var pressStart: Date?

  /// Releases shorter than this are treated as accidental taps and discarded instead of
  /// transcribed — fn is easy to graze, and there's no speech in a fraction of a second.
  private static let minimumHoldDuration: TimeInterval = 0.35

  static var isEnabled: Bool {
    #if APP_STORE
      return false
    #else
      return UserDefaults.standard.bool(forKey: UserDefaultsKeys.holdFnToDictate)
    #endif
  }

  func setup() {
    #if !APP_STORE
      // The flagsChanged monitors stay installed permanently: they fire only on modifier
      // presses and every event is gated on the setting, so a disabled feature costs nothing.
      // Without Accessibility permission the global monitor simply receives no events.
      globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
        [weak self] event in
        self?.handleFlagsChanged(event)
      }
      localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
        [weak self] event in
        self?.handleFlagsChanged(event)
        return event
      }
    #endif
  }

  private func handleFlagsChanged(_ event: NSEvent) {
    guard event.keyCode == UInt16(kVK_Function) else { return }
    if event.modifierFlags.contains(.function) {
      fnDown()
    } else {
      fnUp()
    }
  }

  private func fnDown() {
    guard Self.isEnabled, pressStart == nil else { return }
    guard delegate?.fnPushToTalkStart() == true else { return }
    DebugLogger.log("SHORTCUTS: Fn held — push-to-talk recording started")
    pressStart = Date()
    installKeyDownMonitors()
  }

  private func fnUp() {
    guard let start = pressStart else { return }
    endSession()
    if Date().timeIntervalSince(start) >= Self.minimumHoldDuration {
      DebugLogger.log("SHORTCUTS: Fn released — stopping push-to-talk recording")
      delegate?.fnPushToTalkFinish()
    } else {
      DebugLogger.log("SHORTCUTS: Fn tap too short — discarding recording")
      delegate?.fnPushToTalkDiscard()
    }
  }

  /// A regular key pressed while fn is held means fn is being used as a modifier
  /// (fn+arrow, fn+backspace, …) — abort the recording instead of transcribing the accident.
  private func keyDownDuringHold() {
    guard pressStart != nil else { return }
    DebugLogger.log("SHORTCUTS: Key pressed while Fn held — fn is a modifier, discarding recording")
    endSession()
    delegate?.fnPushToTalkDiscard()
  }

  /// keyDown monitors exist only for the duration of an fn hold, so the app never observes
  /// keystrokes outside of an active push-to-talk session.
  private func installKeyDownMonitors() {
    globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
      [weak self] _ in
      self?.keyDownDuringHold()
    }
    localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      self?.keyDownDuringHold()
      return event
    }
  }

  private func endSession() {
    pressStart = nil
    if let monitor = globalKeyDownMonitor {
      NSEvent.removeMonitor(monitor)
      globalKeyDownMonitor = nil
    }
    if let monitor = localKeyDownMonitor {
      NSEvent.removeMonitor(monitor)
      localKeyDownMonitor = nil
    }
  }

  deinit {
    endSession()
    if let monitor = globalFlagsMonitor { NSEvent.removeMonitor(monitor) }
    if let monitor = localFlagsMonitor { NSEvent.removeMonitor(monitor) }
  }
}
