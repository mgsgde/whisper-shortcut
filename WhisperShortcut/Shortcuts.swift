import Foundation
import HotKey

protocol ShortcutDelegate: AnyObject {
  func toggleDictation()
  func togglePrompting()
  func readSelectedText()
  func openSettings()
}

// Configurable shortcuts using ShortcutConfigManager
class Shortcuts {
  weak var delegate: ShortcutDelegate?

  private var toggleDictationKey: HotKey?
  private var togglePromptingKey: HotKey?
  private var readSelectedTextKey: HotKey?
  private var openSettingsKey: HotKey?
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

    // Create read selected text shortcut (only if enabled)
    if config.readSelectedText.isEnabled {
      readSelectedTextKey = HotKey(
        key: config.readSelectedText.key, modifiers: config.readSelectedText.modifiers)
      readSelectedTextKey?.keyDownHandler = { [weak self] in
        self?.delegate?.readSelectedText()
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
    readSelectedTextKey = nil
    openSettingsKey = nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
