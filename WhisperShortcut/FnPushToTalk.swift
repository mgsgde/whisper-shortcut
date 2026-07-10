import AppKit
import Carbon.HIToolbox
import Foundation

protocol FnPushToTalkDelegate: AnyObject {
  /// Attempt to start a Dictate recording. Returns true only if a recording actually started.
  func fnPushToTalkStart() -> Bool
  /// Stop the recording and transcribe (normal stop path, including tail capture).
  func fnPushToTalkFinish()
  /// Stop the recording and drop the audio (fn used as a modifier during the initial hold).
  func fnPushToTalkDiscard()
  /// Whether the fn-initiated dictation recording is still running. A toggled recording can be
  /// stopped elsewhere (menu bar, ⌘-shortcut), in which case the next fn press must start
  /// fresh instead of trying to stop a recording that no longer exists.
  func fnPushToTalkIsRecording() -> Bool
  /// Whether a dictation transcription is currently processing (cancellable via fn tap).
  func fnPushToTalkIsProcessing() -> Bool
  /// Cancel the in-flight transcription (same behavior as the dictation shortcut).
  func fnPushToTalkCancelProcessing()
}

/// Fn (Globe) key dictation, opt-in via Settings → Dictate. Two gestures share the key:
/// - Hold: fn-down starts a Dictate recording, releasing the key stops and transcribes it.
/// - Tap: a short press starts a recording that keeps running after release; the next fn
///   press stops and transcribes it.
/// - Tap while transcribing: cancels the in-flight transcription, like the dictation shortcut.
///
/// Fn is a modifier, not a regular key, so it can't be a Carbon hotkey like the other
/// shortcuts — it's observed through NSEvent flagsChanged monitors instead. Global monitors
/// only deliver key events when the app is trusted for Accessibility, the same permission
/// story as auto-paste, which is why the feature is absent from the App Store build.
final class FnPushToTalk {
  weak var delegate: FnPushToTalkDelegate?

  /// Lifecycle of an fn-initiated recording.
  private enum State {
    /// No fn-initiated recording.
    case idle
    /// Fn is down and a recording is running; value is when fn went down. Resolves on
    /// release into push-to-talk (long hold) or a toggled recording (short tap).
    case holding(since: Date)
    /// A tap-started recording is running with fn up, waiting for the stop press.
    case toggled
    /// Fn is down again during a toggled recording. Release stops and transcribes; a
    /// regular key press means fn was a modifier and the recording keeps running.
    case stopping
    /// Fn went down while a transcription is processing. Release cancels it (same as the
    /// dictation shortcut); a regular key press means fn was a modifier and it survives.
    case cancelling
  }

  private var state: State = .idle

  private var globalFlagsMonitor: Any?
  private var localFlagsMonitor: Any?
  private var globalKeyDownMonitor: Any?
  private var localKeyDownMonitor: Any?

  /// Presses shorter than this are taps (toggle the recording on), longer ones are
  /// push-to-talk holds (release stops and transcribes).
  private static let maximumTapDuration: TimeInterval = 0.35

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
    guard Self.isEnabled else { return }
    switch state {
    case .idle:
      if delegate?.fnPushToTalkIsProcessing() == true {
        // Don't cancel yet — if a regular key follows, fn is being used as a modifier and
        // the transcription must survive. Release decides.
        state = .cancelling
        installKeyDownMonitors()
      } else {
        startRecording()
      }
    case .toggled:
      if delegate?.fnPushToTalkIsRecording() == true {
        // Second press of a toggle: don't stop yet — if a regular key follows, fn is being
        // used as a modifier and the recording must survive. Release decides.
        state = .stopping
        installKeyDownMonitors()
      } else {
        // The toggled recording was stopped elsewhere; this press starts fresh.
        state = .idle
        fnDown()
      }
    case .holding, .stopping, .cancelling:
      break  // Repeated fn-down without a release in between; nothing to do.
    }
  }

  private func startRecording() {
    guard delegate?.fnPushToTalkStart() == true else { return }
    DebugLogger.log("SHORTCUTS: Fn down — recording started")
    state = .holding(since: Date())
    installKeyDownMonitors()
  }

  private func fnUp() {
    switch state {
    case .idle, .toggled:
      break
    case .holding(let since):
      removeKeyDownMonitors()
      if Date().timeIntervalSince(since) < Self.maximumTapDuration {
        DebugLogger.log("SHORTCUTS: Fn tapped — recording toggled on, tap Fn again to stop")
        state = .toggled
      } else {
        DebugLogger.log("SHORTCUTS: Fn released — stopping push-to-talk recording")
        state = .idle
        delegate?.fnPushToTalkFinish()
      }
    case .stopping:
      DebugLogger.log("SHORTCUTS: Fn tapped again — stopping toggled recording")
      removeKeyDownMonitors()
      state = .idle
      delegate?.fnPushToTalkFinish()
    case .cancelling:
      DebugLogger.log("SHORTCUTS: Fn tapped during transcription — cancelling")
      removeKeyDownMonitors()
      state = .idle
      delegate?.fnPushToTalkCancelProcessing()
    }
  }

  /// A regular key pressed while fn is held means fn is being used as a modifier
  /// (fn+arrow, fn+backspace, …).
  private func keyDownDuringHold() {
    switch state {
    case .idle, .toggled:
      break
    case .holding:
      // The recording only exists because of this fn press — abort it instead of
      // transcribing the accident.
      DebugLogger.log("SHORTCUTS: Key pressed while Fn held — fn is a modifier, discarding recording")
      removeKeyDownMonitors()
      state = .idle
      delegate?.fnPushToTalkDiscard()
    case .stopping:
      // The user deliberately toggled this recording on earlier — keep it running.
      DebugLogger.log("SHORTCUTS: Key pressed while Fn held — fn is a modifier, keeping toggled recording")
      removeKeyDownMonitors()
      state = .toggled
    case .cancelling:
      // fn+key during processing — don't kill the transcription.
      DebugLogger.log("SHORTCUTS: Key pressed while Fn held — fn is a modifier, keeping transcription")
      removeKeyDownMonitors()
      state = .idle
    }
  }

  /// keyDown monitors exist only while fn is physically held, so the app never observes
  /// keystrokes outside of an active fn press.
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

  private func removeKeyDownMonitors() {
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
    removeKeyDownMonitors()
    if let monitor = globalFlagsMonitor { NSEvent.removeMonitor(monitor) }
    if let monitor = localFlagsMonitor { NSEvent.removeMonitor(monitor) }
  }
}
