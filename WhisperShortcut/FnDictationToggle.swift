import AppKit
import Carbon.HIToolbox
import Foundation

protocol FnDictationToggleDelegate: AnyObject {
  /// Attempt to start a Dictate recording. Returns true only if a recording actually started.
  func fnDictationStart() -> Bool
  /// Stop the recording and transcribe (normal stop path, including tail capture).
  func fnDictationStop()
  /// Stop the recording and drop the audio (fn used as a modifier right after it started).
  func fnDictationDiscard()
  /// Whether the fn-initiated dictation recording is still running. The recording can be
  /// stopped elsewhere (menu bar, ⌘-shortcut), in which case the next fn press must start
  /// fresh instead of trying to stop a recording that no longer exists.
  func fnDictationIsRecording() -> Bool
  /// Whether a dictation transcription is currently processing (cancellable via fn press).
  func fnDictationIsProcessing() -> Bool
  /// Cancel the in-flight transcription (same behavior as the dictation shortcut).
  func fnDictationCancelProcessing()
}

/// Fn (Globe) key dictation, opt-in via Settings → Dictate. The key is a pure toggle:
/// - First press: starts a Dictate recording, which keeps running after the key is released.
/// - Second press: stops the recording and transcribes it.
/// - Press while transcribing: cancels the in-flight transcription, like the dictation
///   shortcut — but only once the recording has been in flight longer than
///   `cancelGuardWindow`, so the press that starts the next dictation can't destroy the one
///   just finished.
///
/// There is deliberately no hold-to-talk gesture: a press-duration threshold cannot tell an
/// unhurried toggle press from a deliberate hold, so every slow toggle press ended the
/// recording on release instead of starting it.
///
/// Both toggle edges resolve on key *release*, not on key down, because fn is also a real
/// modifier: only once the key comes up without a regular keystroke in between is it certain
/// that the user meant "dictate" and not fn+arrow / fn+backspace / an emoji-picker press. The
/// recording itself still starts on key down so the indicator appears immediately; it is
/// discarded again if a regular key follows.
///
/// Fn is a modifier, not a regular key, so it can't be a Carbon hotkey like the other
/// shortcuts — it's observed through NSEvent flagsChanged monitors instead. Global monitors
/// only deliver key events when the app is trusted for Accessibility, the same permission
/// story as auto-paste, which is why the feature is absent from the App Store build.
final class FnDictationToggle {
  weak var delegate: FnDictationToggleDelegate?

  /// Lifecycle of an fn-initiated recording.
  private enum State {
    /// No fn-initiated recording.
    case idle
    /// Fn is down and a recording has just started. Release confirms it; a regular key press
    /// means fn was a modifier and the recording is discarded.
    case starting
    /// The recording is running with fn up, waiting for the stop press.
    case recording
    /// Fn is down again during a running recording. Release stops and transcribes; a
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

  /// How long the cancel gesture stays disarmed after a recording is handed off for
  /// transcription.
  ///
  /// Stopping a recording arms the cancel gesture immediately, and a round trip takes ~0.8–2.4s,
  /// so the press that a user means as "start my next dictation" lands while the previous one is
  /// still in flight and destroys it instead. Eight days of logs showed 32 cancellations and
  /// every one of them fired within 2.2s of the stop press — half within 300ms, which is below
  /// the time it takes to see the transcribing state and decide to abort. The gesture was never
  /// once used for its actual purpose (aborting a transcription that is dragging on), and that
  /// purpose only arises after a couple of seconds anyway, so disarming it for that window
  /// costs nothing real.
  private static let cancelGuardWindow: TimeInterval = 2.0

  /// When the current transcription was handed off, or nil if none is pending.
  private var transcriptionStartedAt: Date?

  static var isEnabled: Bool {
    #if APP_STORE
      return false
    #else
      return UserDefaults.standard.bool(forKey: UserDefaultsKeys.fnKeyDictation)
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
      if delegate?.fnDictationIsProcessing() == true {
        guard !isWithinCancelGuardWindow else {
          // The user is almost certainly reaching for the next dictation, not aborting the one
          // they just finished. Swallow the press so the transcription survives.
          DebugLogger.log("SHORTCUTS: Fn pressed right after stopping — ignoring, transcription kept")
          return
        }
        // Don't cancel yet — if a regular key follows, fn is being used as a modifier and
        // the transcription must survive. Release decides.
        state = .cancelling
        installKeyDownMonitors()
      } else {
        startRecording()
      }
    case .recording:
      if delegate?.fnDictationIsRecording() == true {
        // Second press of the toggle: don't stop yet — if a regular key follows, fn is being
        // used as a modifier and the recording must survive. Release decides.
        state = .stopping
        installKeyDownMonitors()
      } else {
        // The recording was stopped elsewhere; this press starts fresh.
        state = .idle
        fnDown()
      }
    case .starting, .stopping, .cancelling:
      break  // Repeated fn-down without a release in between; nothing to do.
    }
  }

  private func startRecording() {
    guard delegate?.fnDictationStart() == true else { return }
    DebugLogger.log("SHORTCUTS: Fn pressed — recording started, press Fn again to stop")
    // A new recording only starts when nothing is processing, so any pending stamp is stale.
    transcriptionStartedAt = nil
    state = .starting
    installKeyDownMonitors()
  }

  private func fnUp() {
    switch state {
    case .idle, .recording:
      break
    case .starting:
      // No duration check: however long the key was held, the recording keeps running until
      // the next press stops it.
      removeKeyDownMonitors()
      state = .recording
    case .stopping:
      DebugLogger.log("SHORTCUTS: Fn pressed again — stopping recording")
      removeKeyDownMonitors()
      state = .idle
      stopRecording()
    case .cancelling:
      DebugLogger.log("SHORTCUTS: Fn pressed during transcription — cancelling")
      removeKeyDownMonitors()
      state = .idle
      transcriptionStartedAt = nil
      delegate?.fnDictationCancelProcessing()
    }
  }

  /// Hands the recording off to transcription and starts the cancel guard window.
  private func stopRecording() {
    transcriptionStartedAt = Date()
    delegate?.fnDictationStop()
  }

  /// True while the cancel gesture is still disarmed after a hand-off. Also clears the stamp once
  /// the window has passed, so a later press takes the normal cancel path.
  private var isWithinCancelGuardWindow: Bool {
    guard let startedAt = transcriptionStartedAt else { return false }
    guard Date().timeIntervalSince(startedAt) < Self.cancelGuardWindow else {
      transcriptionStartedAt = nil
      return false
    }
    return true
  }

  /// A regular key pressed while fn is held means fn is being used as a modifier
  /// (fn+arrow, fn+backspace, …).
  private func keyDownDuringHold() {
    switch state {
    case .idle, .recording:
      break
    case .starting:
      // The recording only exists because of this fn press — abort it instead of
      // transcribing the accident.
      DebugLogger.log("SHORTCUTS: Key pressed while Fn held — fn is a modifier, discarding recording")
      removeKeyDownMonitors()
      state = .idle
      delegate?.fnDictationDiscard()
    case .stopping:
      // The user deliberately started this recording earlier — keep it running.
      DebugLogger.log("SHORTCUTS: Key pressed while Fn held — fn is a modifier, keeping recording")
      removeKeyDownMonitors()
      state = .recording
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
