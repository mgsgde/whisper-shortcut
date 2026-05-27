import AppKit
import Carbon.HIToolbox
import HotKey
import SwiftUI

/// Reusable Settings row for capturing a global keyboard shortcut.
///
/// Replaces the old text-input parser: the user clicks "Record", presses the
/// desired combination once, and we capture the raw `NSEvent`. Storage stays
/// layout-independent via `carbonKeyCode`, but we also persist the user's
/// `charactersIgnoringModifiers` so the UI shows the letter printed on their
/// physical keyboard (e.g. "Z" on a German layout for the same keycode that's
/// "Y" on US-QWERTY).
///
/// Rules:
/// - At least one of ⌘ / ⌥ / ⌃ / ⇧ is required, except for F1–F12 which may be
///   modifier-less.
/// - Escape (with no modifiers) cancels recording.
/// - Unsupported keycodes (no matching `HotKey.Key`) show an inline error and
///   keep the recorder open.
struct ShortcutRecorderRow: View {
  let label: String
  @Binding var shortcut: ShortcutDefinition?
  let defaultShortcut: ShortcutDefinition
  let focusedField: SettingsFocusField
  @FocusState.Binding var currentFocus: SettingsFocusField?
  let onChanged: (() -> Void)?
  let validate: ((ShortcutDefinition?, SettingsFocusField) -> String?)?

  @State private var isRecording = false
  @State private var localMonitor: Any?
  @State private var validationError: String?
  @State private var transientMessage: String?

  init(
    label: String,
    shortcut: Binding<ShortcutDefinition?>,
    defaultShortcut: ShortcutDefinition,
    focusedField: SettingsFocusField,
    currentFocus: FocusState<SettingsFocusField?>.Binding,
    onChanged: (() -> Void)? = nil,
    validate: ((ShortcutDefinition?, SettingsFocusField) -> String?)? = nil
  ) {
    self.label = label
    self._shortcut = shortcut
    self.defaultShortcut = defaultShortcut
    self.focusedField = focusedField
    self._currentFocus = currentFocus
    self.onChanged = onChanged
    self.validate = validate
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 16) {
        Text(label)
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        shortcutDisplay
          .frame(maxWidth: SettingsConstants.shortcutMaxWidth, alignment: .leading)

        Spacer()
      }

      // Inline message: either a transient hint ("⌘/⌥/⌃/⇧ required") or a
      // validation error. Transient takes precedence while recording.
      if let message = transientMessage ?? validationError {
        HStack {
          Spacer()
            .frame(width: SettingsConstants.labelWidth)

          HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption2)
              .foregroundColor(.red.opacity(0.8))

            Text(message)
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .frame(maxWidth: SettingsConstants.shortcutMaxWidth, alignment: .leading)

          Spacer()
        }
        .padding(.top, 2)
      }
    }
    .onDisappear {
      stopRecording()
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private var shortcutDisplay: some View {
    HStack(spacing: 8) {
      ZStack {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color(.controlBackgroundColor))
          .frame(height: SettingsConstants.textFieldHeight)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(
                borderColor,
                lineWidth: isRecording ? 1.5 : 1
              )
          )

        HStack {
          Text(currentDisplayText)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(isRecording ? .secondary : .primary)
            .padding(.leading, 10)
            .padding(.trailing, 6)
          Spacer()
        }
      }
      .frame(minWidth: 140)
      .focused($currentFocus, equals: focusedField)
      .onTapGesture {
        if !isRecording { startRecording() }
      }

      Button(isRecording ? "Cancel" : "Record") {
        if isRecording {
          stopRecording()
        } else {
          startRecording()
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)

      if !isRecording, shortcut != nil {
        Button {
          shortcut = nil
          validationError = validate?(nil, focusedField)
          if validationError == nil {
            onChanged?()
          }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear shortcut")
      }
    }
  }

  private var currentDisplayText: String {
    if isRecording {
      return "Press a key…"
    }
    if let s = shortcut, s.isEnabled {
      return s.displayString
    }
    return "Not set"
  }

  private var borderColor: Color {
    if validationError != nil { return Color.red.opacity(0.7) }
    if isRecording { return Color.accentColor }
    return Color.clear
  }

  // MARK: - Recording lifecycle

  private func startRecording() {
    guard !isRecording else { return }
    isRecording = true
    transientMessage = nil
    validationError = nil
    currentFocus = focusedField

    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      // Only intercept while still recording (handler stays installed between
      // events; we tear it down on capture/cancel).
      guard isRecording else { return event }
      switch event.type {
      case .keyDown:
        handleKeyDown(event)
        return nil  // Consume — don't let Settings window process it.
      case .flagsChanged:
        // Modifier press by itself; ignore (we wait for the real key).
        return nil
      default:
        return event
      }
    }
  }

  private func stopRecording() {
    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
      localMonitor = nil
    }
    isRecording = false
    transientMessage = nil
  }

  private func handleKeyDown(_ event: NSEvent) {
    let keyCode = event.keyCode
    let rawMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let mods: NSEvent.ModifierFlags = rawMods.intersection([.command, .option, .control, .shift])
    let captured = event.charactersIgnoringModifiers

    // Cancel rule: Escape with no modifiers exits recording, no change.
    if keyCode == UInt16(kVK_Escape), mods.isEmpty {
      stopRecording()
      return
    }

    // Resolve carbon keycode → HotKey.Key
    guard let resolvedKey = Key(carbonKeyCode: UInt32(keyCode)) else {
      transientMessage = "This key is not supported"
      return
    }

    // Modifier rule: at least one ⌘/⌥/⌃/⇧, except F1–F12.
    let isFunctionKey: Bool = {
      switch resolvedKey {
      case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
        return true
      default:
        return false
      }
    }()
    if mods.isEmpty, !isFunctionKey {
      transientMessage = "At least ⌘/⌥/⌃/⇧ required"
      return
    }

    let newShortcut = ShortcutDefinition(
      key: resolvedKey,
      modifiers: mods,
      isEnabled: true,
      displayCharacter: captured
    )

    // Run external validation (e.g. duplicate detection).
    if let error = validate?(newShortcut, focusedField) {
      validationError = error
      transientMessage = nil
      stopRecording()
      return
    }

    shortcut = newShortcut
    validationError = nil
    transientMessage = nil
    stopRecording()
    onChanged?()
  }
}
