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
/// - Non-F-keys need at least one of ⌘ / ⌥ / ⌃. Shift alone is rejected because
///   macOS routes `Shift + printable` to text input rather than to Carbon's
///   hotkey handler (binding `Shift+<` would just type `>`); accepting it
///   would silently produce a binding that never fires.
/// - F1–F12 can be bound with any modifier set, including no modifier at all.
/// - Escape (with no modifiers) cancels recording.
/// - Unsupported keycodes (no matching `HotKey.Key`) show an inline error and
///   keep the recorder open.
/// - When the captured shortcut conflicts with another binding, the row enters
///   a "pending conflict" state and offers an explicit "Reassign from X" button
///   rather than dead-ending the user with a red error.
struct ShortcutRecorderRow: View {
  let label: String
  @Binding var shortcut: ShortcutDefinition?
  let focusedField: SettingsFocusField
  @FocusState.Binding var currentFocus: SettingsFocusField?
  let onChanged: (() -> Void)?
  /// Returns `nil` if the candidate doesn't conflict, otherwise the field and
  /// user-visible label of the existing binding that owns this combo.
  let findConflict: ((ShortcutDefinition, SettingsFocusField) -> ShortcutConflict?)?
  /// Clears the binding for the given field (no save — recorder's `onChanged`
  /// triggers a single save afterwards that captures both the cleared slot and
  /// the new assignment).
  let clearShortcut: ((SettingsFocusField) -> Void)?

  @State private var isRecording = false
  @State private var localMonitor: Any?
  @State private var transientMessage: String?
  @State private var pendingShortcut: ShortcutDefinition?
  @State private var pendingConflict: ShortcutConflict?

  /// Stop-callback for the row currently in recording mode. Enforces "only one row records
  /// at a time": when a second row enters recording, it asks the previous row to cancel its
  /// own recording first. Without this, both rows install local NSEvent monitors and both
  /// would write the next keystroke into their respective shortcut bindings.
  private static var activeRecorderCancel: (() -> Void)?

  init(
    label: String,
    shortcut: Binding<ShortcutDefinition?>,
    focusedField: SettingsFocusField,
    currentFocus: FocusState<SettingsFocusField?>.Binding,
    onChanged: (() -> Void)? = nil,
    findConflict: ((ShortcutDefinition, SettingsFocusField) -> ShortcutConflict?)? = nil,
    clearShortcut: ((SettingsFocusField) -> Void)? = nil
  ) {
    self.label = label
    self._shortcut = shortcut
    self.focusedField = focusedField
    self._currentFocus = currentFocus
    self.onChanged = onChanged
    self.findConflict = findConflict
    self.clearShortcut = clearShortcut
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

      // Inline message below the row: conflict warning, modifier-required hint,
      // or unsupported-key hint. Mutually exclusive — conflict takes precedence.
      if let conflict = pendingConflict {
        captionRow(
          icon: "exclamationmark.triangle.fill",
          iconColor: .orange,
          text: "Currently used by \(conflict.label)"
        )
      } else if let message = transientMessage {
        captionRow(
          icon: "exclamationmark.triangle.fill",
          iconColor: .red.opacity(0.8),
          text: message
        )
      }
    }
    .onDisappear {
      stopRecording()
      clearPending()
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
              .stroke(borderColor, lineWidth: (isRecording || pendingConflict != nil) ? 1.5 : 1)
          )

        HStack {
          Text(currentDisplayText)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(textColor)
            .padding(.leading, 10)
            .padding(.trailing, 6)
          Spacer()
        }
      }
      .frame(minWidth: 140)
      .focused($currentFocus, equals: focusedField)
      .onTapGesture {
        if !isRecording, pendingConflict == nil { startRecording() }
      }

      if pendingConflict != nil {
        Button("Reassign") { reassign() }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        Button("Cancel") { clearPending() }
          .buttonStyle(.bordered)
          .controlSize(.small)
      } else {
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
            onChanged?()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .help("Clear shortcut")
        }
      }
    }
  }

  @ViewBuilder
  private func captionRow(icon: String, iconColor: Color, text: String) -> some View {
    HStack {
      Spacer()
        .frame(width: SettingsConstants.labelWidth)

      HStack(spacing: 4) {
        Image(systemName: icon)
          .font(.caption2)
          .foregroundColor(iconColor)

        Text(text)
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: SettingsConstants.shortcutMaxWidth, alignment: .leading)

      Spacer()
    }
    .padding(.top, 2)
  }

  private var currentDisplayText: String {
    if let pending = pendingShortcut { return pending.displayString }
    if isRecording { return "Press a key…" }
    if let s = shortcut, s.isEnabled { return s.displayString }
    return "Not set"
  }

  private var borderColor: Color {
    if pendingConflict != nil { return Color.orange.opacity(0.8) }
    if isRecording { return Color.accentColor }
    return Color.clear
  }

  private var textColor: Color {
    if pendingConflict != nil { return .secondary }
    if isRecording { return .secondary }
    return .primary
  }

  // MARK: - Recording lifecycle

  private func startRecording() {
    guard !isRecording else { return }
    // If another row is already recording, ask it to stop first so its monitor is torn down
    // before ours is installed — otherwise both rows would consume the same keystroke.
    Self.activeRecorderCancel?()
    Self.activeRecorderCancel = { stopRecording() }

    isRecording = true
    transientMessage = nil
    currentFocus = focusedField

    // Tear down global HotKey registrations so Carbon doesn't grab the keystroke
    // before our local monitor sees it (e.g. recording ⌘1 while ⌘1 is bound to
    // Toggle Dictation would otherwise trigger dictation instead of capturing).
    NotificationCenter.default.post(name: .shortcutRecordingStarted, object: nil)

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

  /// Tears down the local NSEvent monitor and exits recording mode.
  ///
  /// `skipRearm: true` is used on the success-capture path where the caller's `onChanged`
  /// is about to trigger `saveSettings → .shortcutsChanged`, which re-arms global HotKeys
  /// with the *new* config. Without this flag we'd post `.shortcutRecordingStopped` first
  /// (re-arming with the *old* config), then immediately rearm again with the new config —
  /// wasted work plus a brief window where the just-replaced binding is briefly live.
  private func stopRecording(skipRearm: Bool = false) {
    let wasRecording = isRecording
    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
      localMonitor = nil
    }
    isRecording = false
    transientMessage = nil
    Self.activeRecorderCancel = nil

    // Re-arm global HotKeys. Skip if we weren't actually recording (e.g. onDisappear after
    // an already-finished capture) or if the caller is about to fire `shortcutsChanged`
    // itself (success-capture path).
    if wasRecording && !skipRearm {
      NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
    }
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

    // Modifier rule for global Carbon hotkeys:
    // - F1–F12 are free of modifier requirements (not used in text input).
    // - Everything else needs at least one of ⌘/⌥/⌃. Shift alone is rejected:
    //   macOS routes Shift+<printable> to text input instead of the hotkey
    //   handler (Shift+a = "A", Shift+< = ">"), so Carbon never fires those
    //   bindings. Accepting them in the recorder would silently produce
    //   shortcuts that never trigger.
    let isFunctionKey: Bool = {
      switch resolvedKey {
      case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
        return true
      default:
        return false
      }
    }()
    let commandModifiers = mods.intersection([.command, .option, .control])
    if !isFunctionKey, commandModifiers.isEmpty {
      if mods.isEmpty {
        transientMessage = "At least ⌘/⌥/⌃ required"
      } else {
        // Shift only — macOS won't route this to a global hotkey.
        transientMessage = "Shift alone won't fire — add ⌘/⌥/⌃"
      }
      return
    }

    let newShortcut = ShortcutDefinition(
      key: resolvedKey,
      modifiers: mods,
      isEnabled: true,
      displayCharacter: captured
    )

    // Conflict path: hold the capture in pending state and offer a reassign
    // action instead of silently failing or destructively reassigning.
    if let conflict = findConflict?(newShortcut, focusedField) {
      pendingShortcut = newShortcut
      pendingConflict = conflict
      transientMessage = nil
      // Keep global hotkeys disarmed until the user Reassigns (save → shortcutsChanged)
      // or Cancel (clearPending → shortcutRecordingStopped).
      stopRecording(skipRearm: true)
      return
    }

    shortcut = newShortcut
    transientMessage = nil
    // Rearm explicitly before `onChanged?()` so a failed save doesn't leave global hotkeys
    // permanently disarmed. `onChanged?()` will trigger `saveSettings → .shortcutsChanged`,
    // which rearms again with the new config — accepted as the cost of the safety net.
    stopRecording(skipRearm: true)
    NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
    onChanged?()
  }

  // MARK: - Conflict resolution

  private func reassign() {
    guard let pending = pendingShortcut, let conflict = pendingConflict else { return }
    clearShortcut?(conflict.field)
    shortcut = pending
    clearPending()
    onChanged?()
  }

  private func clearPending() {
    let hadPending = pendingConflict != nil
    pendingShortcut = nil
    pendingConflict = nil
    if hadPending {
      NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
    }
  }
}
