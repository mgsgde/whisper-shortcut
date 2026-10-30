import Foundation
import HotKey

protocol ShortcutDelegate: AnyObject {
  func toggleDictation()
  func togglePrompting()
  /// A template's own shortcut.
  func toggleTemplatePrompting(id: UUID)
  func openSettings()
  func openChat()
  func takeScreenshot()
  #if !APP_STORE
  func readAloud()
  /// Appends the current selection to the Glossary. Selection-based like Read Aloud, so it shares
  /// its build gate: the synthetic ⌘C needs Accessibility, which the App Store build cannot ask for.
  func addSelectionToGlossary()
  #endif
}

// Configurable shortcuts using ShortcutConfigManager
class Shortcuts {
  weak var delegate: ShortcutDelegate?

  // The recording shortcuts are pure toggles: one press starts, the next one stops. There is
  // deliberately no hold-to-talk gesture — no press-duration threshold can tell an unhurried
  // toggle press from a deliberate hold, so slow presses ended the recording they had just
  // started. Fn behaves the same way, see `FnDictationToggle`.

  private var toggleDictationKey: HotKey?
  private var togglePromptingKey: HotKey?
  private var openSettingsKey: HotKey?
  private var openChatKey: HotKey?
  private var screenshotCaptureKey: HotKey?
  private var readAloudKey: HotKey?
  #if !APP_STORE
  private var addToGlossaryKey: HotKey?
  #endif
  /// Hotkeys for templates that have their own shortcut. Empty when nothing is saved, so a user
  /// without templates pays for one UserDefaults read and no extra registration.
  private var templateKeys: [HotKey] = []
  /// True while the Settings recorder has asked the global hotkeys to step aside. A template-list
  /// save during that pause must not register them again, or the recorder never sees the key.
  private var hotkeysSuspended = false
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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(dictationTemplatesChanged),
      name: .dictationTemplatesChanged,
      object: nil
    )
  }

  @objc private func recordingStarted(_ notification: Notification) {
    hotkeysSuspended = true
    cleanup()
  }

  @objc private func recordingStopped(_ notification: Notification) {
    hotkeysSuspended = false
    setupShortcuts(with: currentConfig)
  }

  /// Re-register on the main thread. Ignored while the Settings recorder is open: stopping that
  /// recording calls `setupShortcuts`, which reads the list just saved.
  @objc private func dictationTemplatesChanged() {
    let apply = { [weak self] in
      guard let self, !self.hotkeysSuspended else { return }
      self.setupShortcuts(with: self.currentConfig)
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  func setup() {
    // Setup shortcuts with current configuration
    setupShortcuts(with: currentConfig)

  }

  private func setupShortcuts(with config: ShortcutConfig) {
    // Clean up existing shortcuts
    cleanup()

    // Sidecar: the user's instance owns the global hotkeys. This guard lives here (not in setup())
    // because setupShortcuts is re-called on config change and after recording.
    if AppConstants.isSidecarInstance {
      DebugLogger.log("SHORTCUTS: sidecar instance, not registering global hotkeys")
      return
    }

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

    #if !APP_STORE
    if config.addToGlossary.isEnabled {
      addToGlossaryKey = HotKey(
        key: config.addToGlossary.key, modifiers: config.addToGlossary.modifiers)
      addToGlossaryKey?.keyDownHandler = { [weak self] in
        self?.delegate?.addSelectionToGlossary()
      }
    }
    #endif

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

    registerTemplateShortcuts(config)
  }

  /// One UserDefaults read. With no saved templates that read returns an empty list and nothing
  /// else happens — no hotkey, no conflict check.
  private func registerTemplateShortcuts(_ config: ShortcutConfig) {
    let templates = DictationTemplateStore.load()
    guard !templates.isEmpty else { return }
    let bindings = TemplateShortcuts.activeBindings(templates: templates, appConfig: config)
    var boundIDs = Set<UUID>()
    for (template, shortcut) in bindings {
      let hotKey = HotKey(key: shortcut.key, modifiers: shortcut.modifiers)
      let templateID = template.id
      hotKey.keyDownHandler = { [weak self] in
        self?.delegate?.toggleTemplatePrompting(id: templateID)
      }
      templateKeys.append(hotKey)
      boundIDs.insert(template.id)
      DebugLogger.log("SHORTCUTS: template shortcut \(shortcut.displayString) registered")
    }
    let skipped = templates.contains { template in
      guard template.isUsable, let shortcut = template.shortcut, shortcut.isEnabled else { return false }
      return !boundIDs.contains(template.id)
    }
    if skipped {
      DebugLogger.log("SHORTCUTS: template shortcut skipped — key already used")
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
    openSettingsKey = nil
    openChatKey = nil
    screenshotCaptureKey = nil
    readAloudKey = nil
    #if !APP_STORE
    addToGlossaryKey = nil
    #endif
    templateKeys = []
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
