import Cocoa
import HotKey
import SwiftUI

// Custom text field that ensures proper clipboard support
class APIKeyTextField: NSTextField {
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Handle standard text editing shortcuts
    if event.modifierFlags.contains(.command) {
      switch event.charactersIgnoringModifiers {
      case "v":  // Paste
        if let pasteboard = NSPasteboard.general.string(forType: .string) {
          self.stringValue = pasteboard
          return true
        }
      case "c":  // Copy
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(self.stringValue, forType: .string)
        return true
      case "x":  // Cut
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(self.stringValue, forType: .string)
        self.stringValue = ""
        return true
      case "a":  // Select All
        self.selectText(nil)
        return true
      default:
        break
      }
    }
    return super.performKeyEquivalent(with: event)
  }
}

class SettingsWindowController: NSWindowController {
  private var transcriptionService: TranscriptionService?
  private var currentConfig: ShortcutConfig

  convenience init() {
    print("🔧 Creating SettingsWindowController...")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "WhisperShortcut Settings"
    window.center()

    self.init(window: window)

    // Set delegate after initialization
    window.delegate = self

    // Initialize transcription service for validation
    transcriptionService = TranscriptionService()

    print("🔧 Setting up content...")
    setupContent()
    print("🔧 SettingsWindowController created successfully")
  }

  init(window: NSWindow) {
    // Load the current saved configuration instead of using defaults
    self.currentConfig = ShortcutConfigManager.shared.loadConfiguration()
    super.init(window: window)
  }

  required init?(coder: NSCoder) {
    // Load the current saved configuration instead of using defaults
    self.currentConfig = ShortcutConfigManager.shared.loadConfiguration()
    super.init(coder: coder)
  }

  private func setupContent() {
    guard let window = window else {
      print("❌ No window available for setupContent")
      return
    }

    print("🔧 Setting up content for window: \(window)")

    // Create content view
    let contentView = NSView(frame: window.contentView?.bounds ?? NSRect.zero)
    contentView.translatesAutoresizingMaskIntoConstraints = false

    // Title label
    let titleLabel = NSTextField(labelWithString: "WhisperShortcut Settings")
    titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.alignment = .center
    contentView.addSubview(titleLabel)

    // API Key section
    let apiKeyLabel = NSTextField(labelWithString: "OpenAI API Key:")
    apiKeyLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
    apiKeyLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(apiKeyLabel)

    let apiKeyField = APIKeyTextField()
    apiKeyField.placeholderString = "sk-..."
    apiKeyField.translatesAutoresizingMaskIntoConstraints = false
    apiKeyField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    apiKeyField.isBordered = true
    apiKeyField.bezelStyle = .roundedBezel
    apiKeyField.isEditable = true
    apiKeyField.isSelectable = true
    apiKeyField.usesSingleLineMode = true
    apiKeyField.lineBreakMode = .byTruncatingTail
    apiKeyField.alignment = .left

    // Fix vertical text alignment for AppKit NSTextField
    apiKeyField.cell?.sendsActionOnEndEditing = true
    apiKeyField.cell?.isScrollable = false
    apiKeyField.cell?.wraps = false

    // Set proper cell properties for vertical centering
    apiKeyField.cell?.setAccessibilityFrame(NSRect(x: 0, y: 0, width: 0, height: 0))

    // Load existing API key from Keychain
    if let existingKey = KeychainManager.shared.getAPIKey() {
      apiKeyField.stringValue = existingKey
    }

    contentView.addSubview(apiKeyField)

    // Shortcuts section
    let shortcutsLabel = NSTextField(labelWithString: "Keyboard Shortcuts:")
    shortcutsLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
    shortcutsLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(shortcutsLabel)

    // Start recording shortcut
    let startLabel = NSTextField(labelWithString: "Start Recording:")
    startLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
    startLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(startLabel)

    let startShortcutField = NSTextField()
    startShortcutField.placeholderString = "e.g., ⌘⌥R"
    startShortcutField.translatesAutoresizingMaskIntoConstraints = false
    startShortcutField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    startShortcutField.isBordered = true
    startShortcutField.bezelStyle = .roundedBezel
    startShortcutField.stringValue = currentConfig.startRecording.displayString
    contentView.addSubview(startShortcutField)

    // Stop recording shortcut
    let stopLabel = NSTextField(labelWithString: "Stop Recording:")
    stopLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
    stopLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stopLabel)

    let stopShortcutField = NSTextField()
    stopShortcutField.placeholderString = "e.g., ⌘R"
    stopShortcutField.translatesAutoresizingMaskIntoConstraints = false
    stopShortcutField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    stopShortcutField.isBordered = true
    stopShortcutField.bezelStyle = .roundedBezel
    stopShortcutField.stringValue = currentConfig.stopRecording.displayString
    contentView.addSubview(stopShortcutField)

    // Help text
    let helpText = NSTextField()
    helpText.stringValue = "Use symbols: ⌘ (Cmd), ⌥ (Option), ⌃ (Control), ⇧ (Shift)"
    helpText.font = NSFont.systemFont(ofSize: 12)
    helpText.textColor = NSColor.secondaryLabelColor
    helpText.isEditable = false
    helpText.isSelectable = false
    helpText.isBordered = false
    helpText.backgroundColor = NSColor.clear
    helpText.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(helpText)

    // Skip button for users who want to configure later
    let skipButton = NSButton(title: "Skip for now", target: self, action: #selector(skipSettings))
    skipButton.translatesAutoresizingMaskIntoConstraints = false
    skipButton.bezelStyle = .rounded
    skipButton.keyEquivalent = "s"  // S key for skip
    contentView.addSubview(skipButton)

    // Save button with better styling
    let saveButton = NSButton(title: "Save Settings", target: self, action: #selector(saveSettings))
    saveButton.translatesAutoresizingMaskIntoConstraints = false
    saveButton.keyEquivalent = "\r"  // Enter key
    saveButton.bezelStyle = .rounded
    contentView.addSubview(saveButton)

    // Store references for save action
    apiKeyField.tag = 100
    startShortcutField.tag = 101
    stopShortcutField.tag = 102
    skipButton.tag = 199
    saveButton.tag = 200

    // Set up constraints with improved spacing and margins
    NSLayoutConstraint.activate([
      // Title with balanced top margin
      titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
      titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

      // API Key section
      apiKeyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
      apiKeyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
      apiKeyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

      apiKeyField.topAnchor.constraint(equalTo: apiKeyLabel.bottomAnchor, constant: 8),
      apiKeyField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
      apiKeyField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
      apiKeyField.heightAnchor.constraint(equalToConstant: 24),

      // Shortcuts section
      shortcutsLabel.topAnchor.constraint(equalTo: apiKeyField.bottomAnchor, constant: 24),
      shortcutsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
      shortcutsLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

      // Start recording shortcut
      startLabel.topAnchor.constraint(equalTo: shortcutsLabel.bottomAnchor, constant: 12),
      startLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
      startLabel.widthAnchor.constraint(equalToConstant: 140),

      startShortcutField.topAnchor.constraint(equalTo: startLabel.bottomAnchor, constant: 6),
      startShortcutField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
      startShortcutField.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor, constant: -32),
      startShortcutField.heightAnchor.constraint(equalToConstant: 24),

      // Stop recording shortcut
      stopLabel.topAnchor.constraint(equalTo: startShortcutField.bottomAnchor, constant: 12),
      stopLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
      stopLabel.widthAnchor.constraint(equalToConstant: 140),

      stopShortcutField.topAnchor.constraint(equalTo: stopLabel.bottomAnchor, constant: 6),
      stopShortcutField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
      stopShortcutField.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor, constant: -32),
      stopShortcutField.heightAnchor.constraint(equalToConstant: 24),

      // Help text
      helpText.topAnchor.constraint(equalTo: stopShortcutField.bottomAnchor, constant: 8),
      helpText.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
      helpText.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

      // Buttons
      saveButton.topAnchor.constraint(equalTo: helpText.bottomAnchor, constant: 20),
      saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
      saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32),
      saveButton.widthAnchor.constraint(equalToConstant: 120),
      saveButton.heightAnchor.constraint(equalToConstant: 32),

      skipButton.topAnchor.constraint(equalTo: helpText.bottomAnchor, constant: 20),
      skipButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -12),
      skipButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32),
      skipButton.widthAnchor.constraint(equalToConstant: 100),
      skipButton.heightAnchor.constraint(equalToConstant: 32),
    ])

    // Set content view directly
    window.contentView = contentView

    print(
      "🔧 Content setup complete. Window contentView: \(window.contentView?.subviews.count ?? 0) subviews"
    )

    // Make the API key field the first responder for immediate input
    DispatchQueue.main.async {
      window.makeFirstResponder(apiKeyField)
    }
  }

  @objc private func skipSettings() {
    print("⏭️ Skipping settings configuration")
    window?.close()
  }

  @objc private func saveSettings() {
    print("🎯 SAVE SETTINGS CALLED - WITH VALIDATION!")
    guard let window = window,
      let contentView = window.contentView,
      let apiKeyField = contentView.viewWithTag(100) as? APIKeyTextField,
      let startShortcutField = contentView.viewWithTag(101) as? NSTextField,
      let stopShortcutField = contentView.viewWithTag(102) as? NSTextField,
      let saveButton = contentView.viewWithTag(200) as? NSButton
    else {
      print("❌ Failed to get window, API key field, shortcut fields, or save button")
      return
    }

    let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let startShortcutText = startShortcutField.stringValue.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let stopShortcutText = stopShortcutField.stringValue.trimmingCharacters(
      in: .whitespacesAndNewlines)

    print("🔑 API Key to validate: '\(apiKey.prefix(10))...' (length: \(apiKey.count))")
    print("🎹 Start shortcut: '\(startShortcutText)'")
    print("🎹 Stop shortcut: '\(stopShortcutText)'")

    if apiKey.isEmpty {
      showAlert(title: "Error", message: "Please enter a valid API key")
      return
    }

    if !apiKey.hasPrefix("sk-") {
      showAlert(
        title: "Error", message: "API key must start with 'sk-'. Please check your OpenAI API key.")
      return
    }

    // Parse shortcuts
    let startShortcut = parseShortcut(from: startShortcutText)
    let stopShortcut = parseShortcut(from: stopShortcutText)

    if startShortcut == nil {
      showAlert(
        title: "Error", message: "Invalid start recording shortcut format. Use symbols like ⌘⌥R")
      return
    }

    if stopShortcut == nil {
      showAlert(
        title: "Error", message: "Invalid stop recording shortcut format. Use symbols like ⌘R")
      return
    }

    // Disable the save button and show validating state
    saveButton.isEnabled = false
    saveButton.title = "Validating..."

    print("🔄 Validating API key with OpenAI...")

    // Validate the API key with OpenAI
    Task {
      do {
        _ = try await transcriptionService?.validateAPIKey(apiKey)
        
        await MainActor.run {
          // Re-enable the save button
          saveButton.isEnabled = true
          saveButton.title = "Save Settings"
          
          print("✅ API key validation successful, saving and closing...")
          self.saveAndClose(
            apiKey: apiKey, startShortcut: startShortcut!, stopShortcut: stopShortcut!)
        }
      } catch {
        await MainActor.run {
          // Re-enable the save button
          saveButton.isEnabled = true
          saveButton.title = "Save Settings"
          
          print("❌ API key validation failed: \(error)")

          // Show specific error message based on the type of error
          let errorMessage: String
          let nsError = error as NSError
          switch nsError.code {
          case 401:
            errorMessage = "Invalid API key. Please check that your OpenAI API key is correct."
          case 429:
            errorMessage = "Rate limited by OpenAI. Please wait a moment and try again."
          case 1001:
            errorMessage = "No API key provided. Please enter a valid API key."
          case 1002:
            errorMessage = "Invalid URL. Please check your internet connection."
          case 1003:
            errorMessage = "Invalid response from server. Please try again."
          default:
            errorMessage = "Network error. Please check your internet connection and try again."
          }

          // Don't close the window - just show the error
          self.showAlert(title: "API Key Validation Failed", message: errorMessage)
        }
      }
    }
  }

  private func saveAndClose(
    apiKey: String, startShortcut: ShortcutDefinition, stopShortcut: ShortcutDefinition
  ) {
    print("🔄 Saving settings and closing window...")

    // Save API key
    let apiKeySaved = KeychainManager.shared.saveAPIKey(apiKey)

    // Save shortcuts
    let newConfig = ShortcutConfig(startRecording: startShortcut, stopRecording: stopShortcut)
    ShortcutConfigManager.shared.saveConfiguration(newConfig)
    print("✅ Shortcuts saved")

    if apiKeySaved {
      print("✅ API key saved to Keychain")

      // Close the settings window after successful save
      DispatchQueue.main.async {
        print("🪟 Attempting to close settings window...")
        self.window?.close()
        print("🪟 Window close called")
      }
    } else {
      print("❌ Failed to save API key to Keychain")
      showAlert(title: "Error", message: "Failed to save API key securely. Please try again.")
    }
  }

  private func parseShortcut(from text: String) -> ShortcutDefinition? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    var modifiers: NSEvent.ModifierFlags = []
    var keyString = trimmed

    // Parse modifiers
    if trimmed.contains("⌘") {
      modifiers.insert(.command)
      keyString = keyString.replacingOccurrences(of: "⌘", with: "")
    }
    if trimmed.contains("⌥") {
      modifiers.insert(.option)
      keyString = keyString.replacingOccurrences(of: "⌥", with: "")
    }
    if trimmed.contains("⌃") {
      modifiers.insert(.control)
      keyString = keyString.replacingOccurrences(of: "⌃", with: "")
    }
    if trimmed.contains("⇧") {
      modifiers.insert(.shift)
      keyString = keyString.replacingOccurrences(of: "⇧", with: "")
    }

    // Find the key
    let key = findKey(from: keyString.trimmingCharacters(in: .whitespacesAndNewlines))
    if key == nil {
      print("❌ Could not parse key from: '\(keyString)'")
      return nil
    }

    return ShortcutDefinition(key: key!, modifiers: modifiers)
  }

  private func findKey(from keyString: String) -> Key? {
    let upperKeyString = keyString.uppercased()

    // Letter keys
    if keyString.count == 1 && keyString.rangeOfCharacter(from: CharacterSet.letters) != nil {
      switch upperKeyString {
      case "A": return .a
      case "B": return .b
      case "C": return .c
      case "D": return .d
      case "E": return .e
      case "F": return .f
      case "G": return .g
      case "H": return .h
      case "I": return .i
      case "J": return .j
      case "K": return .k
      case "L": return .l
      case "M": return .m
      case "N": return .n
      case "O": return .o
      case "P": return .p
      case "Q": return .q
      case "R": return .r
      case "S": return .s
      case "T": return .t
      case "U": return .u
      case "V": return .v
      case "W": return .w
      case "X": return .x
      case "Y": return .y
      case "Z": return .z
      default: return nil
      }
    }

    // Number keys
    if keyString.count == 1 && keyString.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil {
      switch keyString {
      case "0": return .zero
      case "1": return .one
      case "2": return .two
      case "3": return .three
      case "4": return .four
      case "5": return .five
      case "6": return .six
      case "7": return .seven
      case "8": return .eight
      case "9": return .nine
      default: return nil
      }
    }

    // Special keys
    switch upperKeyString {
    case "SPACE": return .space
    case "TAB": return .tab
    case "RETURN", "ENTER": return .return
    case "ESCAPE", "ESC": return .escape
    case "DELETE", "BACKSPACE": return .delete
    case "F1": return .f1
    case "F2": return .f2
    case "F3": return .f3
    case "F4": return .f4
    case "F5": return .f5
    case "F6": return .f6
    case "F7": return .f7
    case "F8": return .f8
    case "F9": return .f9
    case "F10": return .f10
    case "F11": return .f11
    case "F12": return .f12
    default: return nil
    }
  }

  private func showAlert(title: String, message: String, completion: (() -> Void)? = nil) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window!) { _ in
      completion?()
    }
  }
}

// MARK: - NSWindowDelegate
extension SettingsWindowController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    // Notify the settings manager that the window is closing
    SettingsManager.shared.windowWillClose()
  }
}

// Settings manager for easy access
class SettingsManager {
  static let shared = SettingsManager()
  private var settingsWindow: SettingsWindowController?

  private init() {}

  func showSettings() {
    print("🔧 SettingsManager.showSettings() called")
    if settingsWindow == nil {
      print("🔧 Creating new SettingsWindowController")
      settingsWindow = SettingsWindowController()
    }

    print("🔧 Showing settings window")
    settingsWindow?.showWindow(nil)
    settingsWindow?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    print("🔧 Settings window should now be visible")
  }

  func windowWillClose() {
    // Reset the window reference when it closes
    settingsWindow = nil
  }
}
