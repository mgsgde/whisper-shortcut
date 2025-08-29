import Foundation
import HotKey

protocol ShortcutDelegate: AnyObject {
  func startRecording()
  func stopRecording()
  func startPrompting()
  func stopPrompting()
  func openChatGPT()
}

// Configurable shortcuts using ShortcutConfigManager
class Shortcuts {
  weak var delegate: ShortcutDelegate?

  private var startKey: HotKey?
  private var stopKey: HotKey?
  private var startPromptKey: HotKey?
  private var stopPromptKey: HotKey?
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

    // Create new shortcuts (only if enabled)
    if config.startRecording.isEnabled {
      startKey = HotKey(key: config.startRecording.key, modifiers: config.startRecording.modifiers)
      startKey?.keyDownHandler = { [weak self] in
        self?.delegate?.startRecording()
      }
    }

    if config.stopRecording.isEnabled {
      stopKey = HotKey(key: config.stopRecording.key, modifiers: config.stopRecording.modifiers)
      stopKey?.keyDownHandler = { [weak self] in
        self?.delegate?.stopRecording()
      }
    }

    if config.startPrompting.isEnabled {
      startPromptKey = HotKey(
        key: config.startPrompting.key, modifiers: config.startPrompting.modifiers)
      startPromptKey?.keyDownHandler = { [weak self] in
        self?.delegate?.startPrompting()
      }
    }

    if config.stopPrompting.isEnabled {
      stopPromptKey = HotKey(
        key: config.stopPrompting.key, modifiers: config.stopPrompting.modifiers)
      stopPromptKey?.keyDownHandler = { [weak self] in
        self?.delegate?.stopPrompting()
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
    startKey = nil
    stopKey = nil
    startPromptKey = nil
    stopPromptKey = nil
    openChatGPTKey = nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
