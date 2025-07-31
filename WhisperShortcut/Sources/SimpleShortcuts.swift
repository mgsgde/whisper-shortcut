import Foundation
import HotKey

protocol ShortcutDelegate: AnyObject {
  func startRecording()
  func stopRecording()
}

// Configurable shortcuts using ShortcutConfigManager
class SimpleShortcuts {
  weak var delegate: ShortcutDelegate?

  private var startKey: HotKey?
  private var stopKey: HotKey?
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
      "🎹 Shortcuts ready: \(currentConfig.startRecording.displayString) (start), \(currentConfig.stopRecording.displayString) (stop)"
    )
  }

  private func setupShortcuts(with config: ShortcutConfig) {
    // Clean up existing shortcuts
    cleanup()

    // Create new shortcuts
    startKey = HotKey(key: config.startRecording.key, modifiers: config.startRecording.modifiers)
    stopKey = HotKey(key: config.stopRecording.key, modifiers: config.stopRecording.modifiers)

    startKey?.keyDownHandler = { [weak self] in
      self?.delegate?.startRecording()
    }

    stopKey?.keyDownHandler = { [weak self] in
      self?.delegate?.stopRecording()
    }
  }

  @objc private func shortcutsChanged(_ notification: Notification) {
    if let newConfig = notification.object as? ShortcutConfig {
      currentConfig = newConfig
      setupShortcuts(with: newConfig)
      print(
        "🎹 Shortcuts updated: \(newConfig.startRecording.displayString) (start), \(newConfig.stopRecording.displayString) (stop)"
      )
    }
  }

  func cleanup() {
    startKey = nil
    stopKey = nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
