import Foundation
import HotKey

protocol ShortcutDelegate: AnyObject {
  func toggleDictation()
  func togglePrompting()
  func togglePromptImprovement()
  func readSelectedText()
  func readAloud()
  func toggleMeeting()
  func openSettings()
  func openGemini()
}

// Configurable shortcuts using ShortcutConfigManager
class Shortcuts {
  weak var delegate: ShortcutDelegate?

  private var toggleDictationKey: HotKey?
  private var togglePromptingKey: HotKey?
  private var togglePromptImprovementKey: HotKey?
  private var readSelectedTextKey: HotKey?
  private var readAloudKey: HotKey?
  private var toggleMeetingKey: HotKey?
  private var openSettingsKey: HotKey?
  private var openGeminiKey: HotKey?
  private var currentConfig: ShortcutConfig

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
        self?.delegate?.toggleDictation()
      }
    }

    if config.startPrompting.isEnabled {
      togglePromptingKey = HotKey(
        key: config.startPrompting.key, modifiers: config.startPrompting.modifiers)
      togglePromptingKey?.keyDownHandler = { [weak self] in
        self?.delegate?.togglePrompting()
      }
    }

    if config.startPromptImprovement.isEnabled {
      togglePromptImprovementKey = HotKey(
        key: config.startPromptImprovement.key, modifiers: config.startPromptImprovement.modifiers)
      togglePromptImprovementKey?.keyDownHandler = { [weak self] in
        self?.delegate?.togglePromptImprovement()
      }
    }

    // Create prompt & read shortcut (only if enabled)
    if config.readSelectedText.isEnabled {
      readSelectedTextKey = HotKey(
        key: config.readSelectedText.key, modifiers: config.readSelectedText.modifiers)
      readSelectedTextKey?.keyDownHandler = { [weak self] in
        self?.delegate?.readSelectedText()
      }
    }

    // Create read aloud shortcut (only if enabled)
    if config.readAloud.isEnabled {
      readAloudKey = HotKey(
        key: config.readAloud.key, modifiers: config.readAloud.modifiers)
      readAloudKey?.keyDownHandler = { [weak self] in
        self?.delegate?.readAloud()
      }
    }

    // Create toggle meeting shortcut (only if enabled)
    if config.toggleMeeting.isEnabled {
      toggleMeetingKey = HotKey(
        key: config.toggleMeeting.key, modifiers: config.toggleMeeting.modifiers)
      toggleMeetingKey?.keyDownHandler = { [weak self] in
        self?.delegate?.toggleMeeting()
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

    // Create Gemini window shortcut (only if enabled)
    if config.openGemini.isEnabled {
      openGeminiKey = HotKey(
        key: config.openGemini.key, modifiers: config.openGemini.modifiers)
      openGeminiKey?.keyDownHandler = { [weak self] in
        self?.delegate?.openGemini()
      }
    }

  }

  @objc private func shortcutsChanged(_ notification: Notification) {
    if let newConfig = notification.object as? ShortcutConfig {
      currentConfig = newConfig
      setupShortcuts(with: newConfig)

    }
  }

  func cleanup() {
    toggleDictationKey = nil
    togglePromptingKey = nil
    togglePromptImprovementKey = nil
    readSelectedTextKey = nil
    readAloudKey = nil
    toggleMeetingKey = nil
    openSettingsKey = nil
    openGeminiKey = nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
