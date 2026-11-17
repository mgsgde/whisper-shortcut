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
/// - F1–F20 can be bound with any modifier set, including no modifier at all. Bare
///   function keys are what programmable keyboards (QMK and friends) emit for a
///   dedicated dictation key, so requiring a modifier would lock those setups out.
/// - Escape (with no modifiers) cancels recording.
/// - Unsupported keycodes (no matching `HotKey.Key`) show an inline error and
///   keep the recorder open.
/// - When the captured shortcut conflicts with another binding, the row enters
///   a "pending conflict" state and offers an explicit "Reassign from X" button
///   rather than dead-ending the user with a red error.
struct ShortcutRecorderRow: View {
  let label: LocalizedStringKey
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
  @State private var transientMessage: LocalizedStringKey?
  @State private var pendingShortcut: ShortcutDefinition?
  @State private var pendingConflict: ShortcutConflict?
  @State private var isHovering = false

  /// Stop-callback for the row currently in recording mode. Enforces "only one row records
  /// at a time": when a second row enters recording, it asks the previous row to cancel its
  /// own recording first. Without this, both rows install local NSEvent monitors and both
  /// would write the next keystroke into their respective shortcut bindings.
  private static var activeRecorderCancel: (() -> Void)?

  init(
    label: LocalizedStringKey,
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
    // A held conflict is only true while the other row still owns the key. Any save of the app
    // shortcuts or the template list (clear, change, reassign elsewhere) re-checks it.
    .onReceive(
      NotificationCenter.default.publisher(for: .shortcutsChanged)
        .merge(with: NotificationCenter.default.publisher(for: .dictationTemplatesChanged))
    ) { _ in
      revalidatePendingConflict()
    }
  }

  // MARK: - Subviews

  /// One control per row, the way System Settings → Keyboard Shortcuts does it: the combination
  /// as keycaps, click to record, ✕ on hover to clear. The old monospaced field + "Record" +
  /// always-visible ✕ read as a text input and showed raw glyph strings (UX review 2026-11-17).
  @ViewBuilder
  private var shortcutDisplay: some View {
    HStack(spacing: 8) {
      ZStack(alignment: .trailing) {
        Button {
          if isRecording {
            stopRecording()
          } else if pendingConflict == nil {
            startRecording()
          }
        } label: {
          recorderLabel
        }
        .buttonStyle(.plain)
        .focused($currentFocus, equals: focusedField)
        .pointerCursorOnHover()
        .help(isRecording ? "Press the new shortcut. Esc cancels, Delete clears." : "Click to record a new shortcut")
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(currentDisplayText))

        // Clear only on hover, like System Settings: an ✕ next to every row is noise on a list
        // people set once.
        if showsClearButton {
          Button {
            shortcut = nil
            onChanged?()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .padding(.trailing, 6)
          .help("Clear shortcut")
          .accessibilityLabel("Clear shortcut")
        }
      }
      .onHover { isHovering = $0 }

      if pendingConflict != nil {
        Button("Reassign") { reassign() }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        Button("Cancel") { clearPending() }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
  }

  private var recorderLabel: some View {
    HStack(spacing: 4) {
      if let keys = displayedKeycaps {
        ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
          Keycap(text: key, dimmed: pendingConflict != nil)
        }
      } else {
        Text(currentDisplayText)
          .font(.callout)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      // Room for the hover ✕, which sits on top of the control (a button inside a button's label
      // does not get the click on macOS).
      Color.clear.frame(width: 16, height: 16)
    }
    .padding(.horizontal, 6)
    .frame(minWidth: 160, minHeight: 28)
    .fixedSize(horizontal: true, vertical: false)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color(.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(borderColor, lineWidth: (isRecording || pendingConflict != nil) ? 2 : 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 6))
  }

  private var showsClearButton: Bool {
    isHovering && !isRecording && pendingConflict == nil && shortcut?.isEnabled == true
  }

  /// The keycaps to draw, or nil when the row shows a text state ("Click to record", "Type
  /// shortcut…").
  private var displayedKeycaps: [String]? {
    if let pending = pendingShortcut { return Self.keycaps(pending.displayString) }
    if isRecording { return nil }
    if let s = shortcut, s.isEnabled { return Self.keycaps(s.displayString) }
    return nil
  }

  /// "⌃⌥⇧K" → ["⌃", "⌥", "⇧", "K"]; "⌥Space" → ["⌥", "Space"]. Modifier glyphs each get a cap, the
  /// rest (a letter, "F5", "Space") is one cap.
  static func keycaps(_ display: String) -> [String] {
    let modifierGlyphs: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
    var caps: [String] = []
    var rest = Substring(display)
    while let first = rest.first, modifierGlyphs.contains(first) {
      caps.append(String(first))
      rest = rest.dropFirst()
    }
    let key = rest.trimmingCharacters(in: .whitespaces)
    if !key.isEmpty { caps.append(key) }
    return caps
  }

  @ViewBuilder
  private func captionRow(icon: String, iconColor: Color, text: LocalizedStringKey) -> some View {
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
    if isRecording { return String(localized: "Type shortcut…") }
    if let s = shortcut, s.isEnabled { return s.displayString }
    return String(localized: "Click to record")
  }

  private var borderColor: Color {
    if pendingConflict != nil { return Color.orange.opacity(0.8) }
    if isRecording { return Color.accentColor }
    return Color(.separatorColor)
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
  /// `skipRearm: true` is used by the pending-conflict path: rearm is deferred until the
  /// user picks Reassign or Cancel, at which point `reassign()` / `clearPending()` post
  /// `.shortcutRecordingStopped` themselves. Callers on the success-capture path leave it
  /// at the default so global HotKeys are rearmed before the async save fires
  /// `.shortcutsChanged`, ensuring a failed save can't leave hotkeys permanently disarmed.
  private func stopRecording(skipRearm: Bool = false) {
    let wasRecording = isRecording
    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
      localMonitor = nil
    }
    isRecording = false
    transientMessage = nil
    // Only clear the cross-row registry slot if we were actually the active recorder. A
    // stale `onDisappear` from a row that was already replaced by a newer recorder would
    // otherwise nil out the new owner's cancel, leaving two monitors live.
    if wasRecording {
      Self.activeRecorderCancel = nil
    }

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

    // Delete (either key) with no modifiers clears the binding, as in System Settings.
    if keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete), mods.isEmpty {
      stopRecording()
      if shortcut != nil {
        shortcut = nil
        onChanged?()
      }
      return
    }

    // Resolve carbon keycode → HotKey.Key
    guard let resolvedKey = Key(carbonKeyCode: UInt32(keyCode)) else {
      transientMessage = "This key is not supported"
      return
    }

    // Modifier rule for global Carbon hotkeys — shared with `get_settings`/`update_settings`'s
    // shortcut entries via `ShortcutValidation.modifierRuleViolation`, so an AI app cannot
    // propose a combination the recorder itself would reject (and vice versa, there is only one
    // rule to keep in sync). F1–F20 are free of modifier requirements (not used in text input;
    // F13–F20 in particular are the keycodes programmable keyboards send for a dedicated key).
    // Everything else needs at least one of ⌘/⌥/⌃ — Shift alone is rejected: macOS routes
    // Shift+<printable> to text input instead of the hotkey handler (Shift+a = "A", Shift+< =
    // ">"), so Carbon never fires those bindings, and accepting them here would silently produce
    // shortcuts that never trigger.
    if let violation = ShortcutValidation.modifierRuleViolation(key: resolvedKey, modifiers: mods) {
      transientMessage = LocalizedStringKey(violation)
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
    // `stopRecording()` posts `.shortcutRecordingStopped` and rearms global HotKeys before
    // the async save fires `.shortcutsChanged`, so a failed save can't leave hotkeys
    // permanently disarmed. The double rearm (old config → new config) is accepted as the
    // cost of the safety net.
    stopRecording()
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

  /// Re-runs the conflict lookup for the held shortcut. Free now: the other binding was cleared
  /// or moved, so the pending key is assigned as the user intended. Still taken, possibly by a
  /// different row: the caption follows the current owner.
  private func revalidatePendingConflict() {
    guard let pending = pendingShortcut, let held = pendingConflict else { return }
    let now = findConflict?(pending, focusedField)
    switch PendingConflictResolution.resolve(held: held, now: now) {
    case .keep:
      break
    case .update(let conflict):
      pendingConflict = conflict
    case .assign:
      pendingShortcut = nil
      pendingConflict = nil
      shortcut = pending
      NotificationCenter.default.post(name: .shortcutRecordingStopped, object: nil)
      onChanged?()
    }
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

/// One key of a shortcut, drawn like the key on the keyboard. System font, not monospaced: the
/// glyphs ⌃⌥⇧⌘ are designed for it, and SF Mono draws ⌃ close to a caret.
struct Keycap: View {
  let text: String
  var dimmed = false

  var body: some View {
    Text(verbatim: text)
      .font(.system(size: 13, weight: .medium))
      .foregroundColor(dimmed ? .secondary : .primary)
      .padding(.horizontal, text.count > 1 ? 6 : 0)
      .frame(minWidth: 20, minHeight: 20)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.primary.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
      )
  }
}

/// What to do with a conflict the recorder row is holding after some shortcut changed elsewhere.
/// Kept outside the view so the rule is testable.
enum PendingConflictResolution: Equatable {
  /// The same row still owns the key: leave the warning.
  case keep
  /// Another row owns it now: show that one.
  case update(ShortcutConflict)
  /// Nobody owns it any more: assign the pending shortcut.
  case assign

  static func resolve(held: ShortcutConflict, now: ShortcutConflict?) -> PendingConflictResolution {
    guard let now else { return .assign }
    return now == held ? .keep : .update(now)
  }
}
