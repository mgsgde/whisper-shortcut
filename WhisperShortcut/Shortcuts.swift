import Foundation
import HotKey

protocol ShortcutDelegate: AnyObject {
  func toggleDictation()
  func togglePrompting()
  func isDictationRecordingActive() -> Bool
  func isPromptRecordingActive() -> Bool
  func openSettings()
  func openChat()
  func takeScreenshot()
  #if !APP_STORE
  func readAloud()
  #endif
}

// Configurable shortcuts using ShortcutConfigManager
class Shortcuts {
  weak var delegate: ShortcutDelegate?

  private var toggleDictationKey: HotKey?
  private var togglePromptingKey: HotKey?
  private var openSettingsKey: HotKey?
  private var openChatKey: HotKey?
  private var screenshotCaptureKey: HotKey?
  private var readAloudKey: HotKey?
  private var currentConfig: ShortcutConfig

  // Push-to-talk: a press that *started* a recording and is held past this threshold
  // stops the recording on release. Shorter presses keep the classic toggle behavior.
  // 1.0s because unhurried toggle-taps run up to ~0.7s — at 0.5s those releases stopped
  // the just-started recording; genuine push-to-talk holds span the whole utterance.
  private static let pushToTalkHoldThreshold: TimeInterval = 1.0
  private var dictationPressStart: Date?
  private var promptingPressStart: Date?

  init() {
    // Load current configuration
    currentConfig = ShortcutConfigManager.shared.loadConfiguration()

    // Listen for configuration changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(shortcutsChanged),
      name: .shortcutsChanged,
      object: nil
    )

    // Pause/resume global hotkeys while the Settings recorder is open, so the
    // recorder's NSEvent local monitor sees the keystroke instead of Carbon
    // firing the global handler.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(recordingStarted),
      name: .shortcutRecordingStarted,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(recordingStopped),
      name: .shortcutRecordingStopped,
      object: nil
    )
  }

  @objc private func recordingStarted(_ notification: Notification) {
    cleanup()
  }

  @objc private func recordingStopped(_ notification: Notification) {
    setupShortcuts(with: currentConfig)
  }

  func setup() {
    // Setup shortcuts with current configuration
    setupShortcuts(with: currentConfig)

  }

  private func setupShortcuts(with config: ShortcutConfig) {
    // Clean up existing shortcuts
    cleanup()

    // Create toggle shortcuts (only if enabled)
    if config.startRecording.isEnabled {
      toggleDictationKey = HotKey(
        key: config.startRecording.key, modifiers: config.startRecording.modifiers)
      toggleDictationKey?.keyDownHandler = { [weak self] in
        guard let self, let delegate = self.delegate else { return }
        let wasRecording = delegate.isDictationRecordingActive()
        delegate.toggleDictation()
        self.dictationPressStart = wasRecording ? nil : Date()
      }
      toggleDictationKey?.keyUpHandler = { [weak self] in
        guard let self, let pressStart = self.dictationPressStart else { return }
        self.dictationPressStart = nil
        if Date().timeIntervalSince(pressStart) >= Self.pushToTalkHoldThreshold,
          self.delegate?.isDictationRecordingActive() == true {
          DebugLogger.log("SHORTCUTS: Push-to-talk release — stopping dictation")
          self.delegate?.toggleDictation()
        }
      }
    }

    if config.startPrompting.isEnabled {
      togglePromptingKey = HotKey(
        key: config.startPrompting.key, modifiers: config.startPrompting.modifiers)
      togglePromptingKey?.keyDownHandler = { [weak self] in
        guard let self, let delegate = self.delegate else { return }
        let wasRecording = delegate.isPromptRecordingActive()
        delegate.togglePrompting()
        self.promptingPressStart = wasRecording ? nil : Date()
      }
      togglePromptingKey?.keyUpHandler = { [weak self] in
        guard let self, let pressStart = self.promptingPressStart else { return }
        self.promptingPressStart = nil
        if Date().timeIntervalSince(pressStart) >= Self.pushToTalkHoldThreshold,
          self.delegate?.isPromptRecordingActive() == true {
          DebugLogger.log("SHORTCUTS: Push-to-talk release — stopping prompt")
          self.delegate?.togglePrompting()
        }
      }
    }

    // Create settings shortcut (only if enabled)
    if config.openSettings.isEnabled {
      openSettingsKey = HotKey(
        key: config.openSettings.key, modifiers: config.openSettings.modifiers)
      openSettingsKey?.keyDownHandler = { [weak self] in
        self?.delegate?.openSettings()
      }
    }

    // Create chat window shortcut (only if enabled)
    if config.openChat.isEnabled {
      openChatKey = HotKey(
        key: config.openChat.key, modifiers: config.openChat.modifiers)
      openChatKey?.keyDownHandler = { [weak self] in
        self?.delegate?.openChat()
      }
    }

    // Create screenshot capture shortcut (only if enabled)
    if config.screenshotCapture.isEnabled {
      screenshotCaptureKey = HotKey(
        key: config.screenshotCapture.key, modifiers: config.screenshotCapture.modifiers)
      screenshotCaptureKey?.keyDownHandler = { [weak self] in
        self?.delegate?.takeScreenshot()
      }
    }

    // Create Read Aloud shortcut (only if enabled). Selection-based Read Aloud copies via ⌘C
    // (Accessibility), so the global shortcut is omitted from the App Store build.
    #if !APP_STORE
    if config.readAloud.isEnabled {
      readAloudKey = HotKey(
        key: config.readAloud.key, modifiers: config.readAloud.modifiers)
      readAloudKey?.keyDownHandler = { [weak self] in
        self?.delegate?.readAloud()
      }
    }
    #endif

  }

  @objc private func shortcutsChanged(_ notification: Notification) {
    if let newConfig = notification.object as? ShortcutConfig {
      currentConfig = newConfig
      setupShortcuts(with: newConfig)

    }
  }

  func cleanup() {
    dictationPressStart = nil
    promptingPressStart = nil
    toggleDictationKey = nil
    togglePromptingKey = nil
    openSettingsKey = nil
    openChatKey = nil
    screenshotCaptureKey = nil
    readAloudKey = nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
