import Foundation
import HotKey

protocol ShortcutDelegate: AnyObject {
  func startRecording()
  func stopRecording()
  func startPrompting()
  func stopPrompting()
}

// Configurable shortcuts using ShortcutConfigManager
class SimpleShortcuts {
  weak var delegate: ShortcutDelegate?

  private var startKey: HotKey?
  private var stopKey: HotKey?
  private var startPromptKey: HotKey?
  private var stopPromptKey: HotKey?
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
    print(
      "🎹 Shortcuts ready: \(currentConfig.startRecording.displayString) (start), \(currentConfig.stopRecording.displayString) (stop), \(currentConfig.startPrompting.displayString) (start prompt), \(currentConfig.stopPrompting.displayString) (stop prompt)"
    )
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
  }

  @objc private func shortcutsChanged(_ notification: Notification) {
    if let newConfig = notification.object as? ShortcutConfig {
      currentConfig = newConfig
      setupShortcuts(with: newConfig)
      print(
        "🎹 Shortcuts updated: \(newConfig.startRecording.displayString) (start), \(newConfig.stopRecording.displayString) (stop), \(newConfig.startPrompting.displayString) (start prompt), \(newConfig.stopPrompting.displayString) (stop prompt)"
      )
    }
  }

  func cleanup() {
    startKey = nil
    stopKey = nil
    startPromptKey = nil
    stopPromptKey = nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
