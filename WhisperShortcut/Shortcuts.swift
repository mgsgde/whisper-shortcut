import Foundation
import HotKey

protocol ShortcutDelegate: AnyObject {
  func toggleDictation()
  func togglePrompting()
  func toggleVoiceResponse()
  func openChatGPT()
}

// Configurable shortcuts using ShortcutConfigManager
class Shortcuts {
  weak var delegate: ShortcutDelegate?

  private var toggleDictationKey: HotKey?
  private var togglePromptingKey: HotKey?
  private var toggleVoiceResponseKey: HotKey?
  private var openChatGPTKey: HotKey?
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

    if config.startVoiceResponse.isEnabled {
      toggleVoiceResponseKey = HotKey(
        key: config.startVoiceResponse.key, modifiers: config.startVoiceResponse.modifiers)
      toggleVoiceResponseKey?.keyDownHandler = { [weak self] in
        self?.delegate?.toggleVoiceResponse()
      }
    }

    if config.openChatGPT.isEnabled {
      openChatGPTKey = HotKey(
        key: config.openChatGPT.key, modifiers: config.openChatGPT.modifiers)
      openChatGPTKey?.keyDownHandler = { [weak self] in
        self?.delegate?.openChatGPT()
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
    toggleVoiceResponseKey = nil
    openChatGPTKey = nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
