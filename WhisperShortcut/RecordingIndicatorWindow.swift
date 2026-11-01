//
//  RecordingIndicatorWindow.swift
//  WhisperShortcut
//
//  A small floating pill at the bottom-center of the screen (Wispr-Flow style) that
//  accompanies the Dictate / Dictate Prompt lifecycle:
//    recording  → live audio-level bars with ✕ (discard) and ✓ (stop & process);
//                 Dictate Prompt grows the pill into a card: what the run acts on, quick
//                 actions, a text field, and the same controls as its footer
//    processing → spinner with ✕ (cancel)
//  and Read Aloud playback:
//    speaking   → ✕ (stop), ⏪ 10 s, ⏸/▶ (pause / resume), ⏩ 10 s, scrubber with elapsed / total,
//                 speed button (cycles 0.75×…2×) — ⏸ becomes a spinner while the next chunk is
//                 loading
//  On success the pill hides immediately — the pasted/copied text itself is the
//  feedback, and lingering UI would cover whatever the user is working on.
//
//  Main-thread only (like PopupNotificationWindow). Visibility is driven by
//  MenuBarController's AppState transitions.
//

import AppKit
import SwiftUI

// MARK: - Model

enum RecordingIndicatorPhase: Equatable {
  case recording
  case processing
  /// Read Aloud audio is playing (or paused). Transport controls live on the pill.
  case speaking
}

final class RecordingIndicatorModel: ObservableObject {
  static let barCount = 10

  @Published var phase: RecordingIndicatorPhase = .recording
  /// The status word next to the spinner / level bars. Names the mode ("Prompting", "Thinking")
  /// so Dictate and Dictate Prompt no longer both read "Listening"/"Transcribing".
  @Published var statusLabel = String(localized: "Listening")
  @Published var levels: [CGFloat] = Array(repeating: 0, count: RecordingIndicatorModel.barCount)
  /// `.speaking` only: whether playback is paused.
  @Published var isPaused = false
  /// `.speaking` only: the player ran out of audio and is waiting for the next synthesized chunk.
  @Published var isBuffering = false
  /// `.speaking` only: the rate currently applied to playback.
  @Published var speed: ReadAloudSpeed = SettingsDefaults.readAloudSpeed
  /// `.speaking` only: playhead, total length and received audio, in seconds of source audio.
  /// `duration` is an estimate until synthesis finishes; `received` bounds where a seek can land.
  @Published var position: TimeInterval = 0
  @Published var duration: TimeInterval = 0
  @Published var received: TimeInterval = 0
  /// `.speaking` only: the user is dragging the scrubber; progress updates leave the knob alone.
  @Published var scrubPosition: TimeInterval?
  /// Dictate Prompt: frequent instructions shown above the pill. Empty when the list is hidden.
  @Published var quickActions: [QuickAction] = []
  /// nil until ↑/↓ moves into the list, so ↩ on an empty field means "use the speech".
  @Published var quickActionIndex: Int?
  @Published var quickActionsVisible = false
  /// Dictate Prompt: what the run will act on, shown in the card's header.
  @Published var quickActionContext: QuickActionContext = .reading
  /// Dictate Prompt: what the user typed into the field under the list. Non-empty text
  /// replaces the spoken instruction.
  @Published var typedPrompt = ""
  /// Dictate Prompt: name of the dictation template bound to the app the user is dictating into,
  /// nil when none is. Shown in the header while nothing is selected; Tab switches it on and off.
  @Published var templateName: String?
  /// Whether stopping applies `templateName`'s template. Starts on; Tab toggles it.
  @Published var templateEnabled = true
  /// The generic template shortcut with several templates: their names, in order (1–9).
  /// Empty when a template's own shortcut started the recording, or there is only one.
  @Published var templateChoices: [String] = []
  /// The highlighted choice; stopping applies it. Starts on the last-used template.
  @Published var templateChoiceIndex = 0
  /// Open until a digit, ↩ or a click picks a template, or Tab switches to Normal.
  @Published var templatePickerOpen = false

  /// The names the card lists right now. A selection closes the picker: selected text is never
  /// sent to a template, so there is nothing to choose.
  var visibleTemplateChoices: [String] {
    guard templatePickerOpen, templateChoices.count > 1 else { return [] }
    if case .selection = quickActionContext { return [] }
    return templateChoices
  }

  func pushLevel(_ normalized: CGFloat) {
    var next = levels
    next.removeFirst()
    next.append(normalized)
    levels = next
  }

  func resetLevels() {
    levels = Array(repeating: 0, count: Self.barCount)
  }
}

// MARK: - SwiftUI Views

private struct LevelBarsView: View {
  let levels: [CGFloat]

  private enum Metrics {
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2.5
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 18
  }

  var body: some View {
    HStack(spacing: Metrics.barSpacing) {
      ForEach(levels.indices, id: \.self) { index in
        Capsule()
          .fill(Color.white)
          .frame(
            width: Metrics.barWidth,
            height: Metrics.minHeight + levels[index] * (Metrics.maxHeight - Metrics.minHeight)
          )
      }
    }
    .frame(height: Metrics.maxHeight)
    .animation(.easeOut(duration: 0.1), value: levels)
  }
}

private struct SpinnerView: View {
  var color: Color = .white.opacity(0.9)
  var size: CGFloat = 14
  @State private var isRotating = false

  var body: some View {
    Circle()
      .trim(from: 0.18, to: 1)
      .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
      .frame(width: size, height: size)
      .rotationEffect(.degrees(isRotating ? 360 : 0))
      .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isRotating)
      .onAppear { isRotating = true }
  }
}

private struct PillCircleButton: View {
  let symbolName: String
  let foreground: Color
  let background: Color
  let accessibilityLabel: LocalizedStringKey
  var isBusy: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(background)
        if isBusy {
          SpinnerView(color: .black, size: 12)
        } else {
          Image(systemName: symbolName)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(foreground)
        }
      }
      .frame(width: 24, height: 24)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .pointerCursorOnHover()
  }
}

/// Small text pill showing the current rate; a click steps to the next speed.
private struct SpeedButton: View {
  let speed: ReadAloudSpeed
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(speed.displayName)
        .font(.system(size: 10, weight: .bold).monospacedDigit())
        .foregroundColor(.white)
        .frame(width: 40, height: 22)
        .background(Capsule().fill(Color(white: 0.28)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("Playback speed — click to change")
    .accessibilityLabel("Playback speed \(speed.displayName); click to change")
    .pointerCursorOnHover()
  }
}

/// Thin track with a knob; dragging previews the target and seeks on release. The track is drawn
/// in three tones: played, received-but-not-played, and not yet synthesized. Drags stop at the
/// end of the received audio — there is nothing to seek into beyond it.
private struct ScrubberView: View {
  @ObservedObject var model: RecordingIndicatorModel
  let onSeek: (TimeInterval) -> Void

  private enum Metrics {
    static let trackHeight: CGFloat = 3
    static let knobSize: CGFloat = 10
    static let hitHeight: CGFloat = 24
  }

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let shown = model.scrubPosition ?? model.position
      let fraction = model.duration > 0 ? min(1, max(0, shown / model.duration)) : 0
      let receivedFraction = model.duration > 0 ? min(1, max(0, model.received / model.duration)) : 0
      let knobX = fraction * width
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.25)).frame(height: Metrics.trackHeight)
        Capsule().fill(Color.white.opacity(0.45))
          .frame(width: receivedFraction * width, height: Metrics.trackHeight)
        Capsule().fill(Color.white).frame(width: knobX, height: Metrics.trackHeight)
        Circle()
          .fill(Color.white)
          .frame(width: Metrics.knobSize, height: Metrics.knobSize)
          .offset(x: knobX - Metrics.knobSize / 2)
      }
      .frame(height: Metrics.hitHeight)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard model.duration > 0 else { return }
            let fraction = min(1, max(0, value.location.x / width))
            model.scrubPosition = min(fraction * model.duration, model.received)
          }
          .onEnded { _ in
            guard let target = model.scrubPosition else { return }
            model.scrubPosition = nil
            model.position = target
            onSeek(target)
          }
      )
    }
    .frame(height: Metrics.hitHeight)
    .accessibilityLabel("Playback position")
    .accessibilityValue(RecordingIndicatorView.timeLabel(model.scrubPosition ?? model.position))
  }
}

/// What a Dictate Prompt run will act on, shown in the card's header so a missed selection is
/// visible before the run, not after (usage review 2026-10-12: invented text pasted because the
/// selection never arrived and nothing on screen said so).
enum QuickActionContext: Equatable {
  /// The synthetic ⌘C is still being polled (at most `DictatePromptSelectionCapture.pollDeadline`).
  case reading
  /// Text the run will edit. `fromClipboard` is the App Store local-model path, where the user
  /// copies first instead of selecting.
  case selection(text: String, fromClipboard: Bool)
  /// Nothing came through: the run writes new text.
  case nothingSelected
  /// Screenshot-selection mode: the model reads the selection off the screen.
  case screenshot
}

private enum QuickActionCardMetrics {
  /// Wide enough to type a real instruction into the field.
  static let width: CGFloat = 360
  static let rowHeight: CGFloat = 28
  static let headerHeight: CGFloat = 28
  static let footerHeight: CGFloat = 40
  static let padding: CGFloat = 4
  static let dividerHeight: CGFloat = 1
  static let dividerSpacing: CGFloat = 4
  static let cornerRadius: CGFloat = 16

  static let typeFieldPlaceholder: LocalizedStringKey = "Type an instruction, or just speak"

  /// Header, `count` rows (quick actions or templates), the text field unless a template
  /// recording hides it, and the recording controls as the footer.
  static func height(count: Int, field: Bool = true) -> CGFloat {
    let divider = dividerHeight + dividerSpacing * 2
    let rows = count + (field ? 1 : 0)
    return padding * 2 + headerHeight + divider + CGFloat(rows) * rowHeight
      + (rows > 0 ? divider : 0) + footerHeight
  }
}

/// Dictate Prompt while recording: one card instead of a list floating over the pill. Top to
/// bottom: what the run acts on, the quick actions (⌃1–9), a text field that has keyboard focus
/// from the start, and the recording controls.
///
/// Nothing is highlighted until ↑/↓ moves into the list, so ↩ on an empty field means the same as
/// ✓ — stop and use what was spoken. Only ⌃digit picks an entry: a bare digit is just text, so a
/// keystroke meant for the app underneath cannot fire an action.
///
/// A dictation template bound to the app underneath shows in the header instead of the "nothing
/// selected" warning: the user is dictating into a field on purpose, and the header says what
/// stopping will do with it and that Tab switches the template off. With a selection there is no
/// template and no Tab hint — a template is never applied to selected text.
///
/// A template recording shows neither quick actions nor the field: a typed or picked instruction
/// would replace the template. Started by the generic template shortcut with several templates,
/// it lists them numbered instead; there is no field, so a bare digit picks one.
private struct QuickActionCardView: View {
  let actions: [QuickAction]
  let selectedIndex: Int?
  let context: QuickActionContext
  let templateName: String?
  let templateEnabled: Bool
  let onToggleTemplate: () -> Void
  /// Empty unless the template picker is open.
  let templateChoices: [String]
  let templateChoiceIndex: Int
  let onChooseTemplate: (Int) -> Void
  let levels: [CGFloat]
  @Binding var typedText: String
  let onSelect: (Int) -> Void
  let onSubmitTyped: () -> Void
  let onDismiss: () -> Void
  let onCancel: () -> Void
  let onConfirm: () -> Void

  @FocusState private var fieldFocused: Bool

  // Trimmed like `submitTyped`: a lone space is not an instruction, so it must not disable ↑/↓/↩.
  private var isTyping: Bool { !typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private var showsPicker: Bool { !templateChoices.isEmpty }
  private var showsField: Bool { templateName == nil }

  var body: some View {
    VStack(spacing: 0) {
      header
      divider
      if showsPicker {
        ForEach(templateChoices.indices, id: \.self) { index in
          templateChoiceRow(index)
        }
      } else {
        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
          actionRow(index: index, action: action)
        }
      }
      if showsField { fieldRow }
      if showsPicker || showsField || !actions.isEmpty { divider }
      footer
    }
    .padding(QuickActionCardMetrics.padding)
    .background(
      RoundedRectangle(cornerRadius: QuickActionCardMetrics.cornerRadius, style: .continuous)
        .fill(Color.black.opacity(0.92))
    )
    .overlay(
      RoundedRectangle(cornerRadius: QuickActionCardMetrics.cornerRadius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Dictate Prompt")
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.1))
      .frame(height: QuickActionCardMetrics.dividerHeight)
      .padding(.vertical, QuickActionCardMetrics.dividerSpacing)
      .padding(.horizontal, 8)
  }

  // MARK: Header

  /// The template header replaces the "nothing selected" one only; while the selection is still
  /// being read, or when there is one, the header is the same as without templates.
  private var showsTemplateHeader: Bool { templateName != nil && context == .nothingSelected }

  /// The header, or — when a template is bound — the header as a button that does what Tab does.
  @ViewBuilder private var header: some View {
    if showsPicker {
      pickerHeader
    } else if showsTemplateHeader, let templateName {
      Button(action: onToggleTemplate) {
        templateHeader(name: templateName)
      }
      .buttonStyle(.plain)
      .help(templateEnabled
        ? String(localized: "Tab or click: run this recording without the template")
        : String(localized: "Tab or click: apply \u{201C}\(templateName)\u{201D}"))
      .accessibilityLabel(templateEnabled
        ? String(localized: "Template \u{201C}\(templateName)\u{201D} is on")
        : String(localized: "No template"))
      .accessibilityHint("Tab")
      .pointerCursorOnHover()
    } else {
      contextHeader
    }
  }

  /// "Praxisnotiz · Tab: Normal" / "Normal · Tab: Praxisnotiz". Tab only changes this recording.
  private func templateHeader(name: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: templateEnabled ? "doc.text.fill" : "text.bubble")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(templateEnabled ? 0.9 : 0.6))
        .frame(width: 16, alignment: .center)
      Text(templateEnabled ? name : String(localized: "Normal"))
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(templateEnabled ? 1 : 0.75))
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
      Text("\u{00B7}")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.35))
      Text(templateEnabled
        ? String(localized: "Tab: Normal")
        : String(localized: "Tab: \(name)"))
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.white.opacity(0.5))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(height: QuickActionCardMetrics.headerHeight)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(templateEnabled ? Color.accentColor.opacity(0.28) : Color.clear)
    )
    .contentShape(Rectangle())
  }

  /// "Choose a template · Tab: Normal". Tab works here too and closes the list.
  private var pickerHeader: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.9))
        .frame(width: 16, alignment: .center)
      Text("Choose a template")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white)
        .lineLimit(1)
      Text("\u{00B7}")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.35))
      Text("Tab: Normal")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.white.opacity(0.5))
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(height: QuickActionCardMetrics.headerHeight)
    .accessibilityElement(children: .combine)
  }

  private var contextHeader: some View {
    HStack(spacing: 8) {
      headerIcon
        .frame(width: 16, alignment: .center)
      headerText
      Spacer(minLength: 0)
      if case .selection(let text, _) = context {
        Text("\(text.count.formatted()) chars")
          .font(.system(size: 10, weight: .medium).monospacedDigit())
          .foregroundColor(.white.opacity(0.45))
          .fixedSize()
      }
    }
    .padding(.horizontal, 8)
    .frame(height: QuickActionCardMetrics.headerHeight)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var headerIcon: some View {
    switch context {
    case .reading:
      SpinnerView(color: .white.opacity(0.6), size: 10)
    case .selection(_, let fromClipboard):
      Image(systemName: fromClipboard ? "doc.on.clipboard" : "text.quote")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.6))
    case .nothingSelected:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Self.warning)
    case .screenshot:
      Image(systemName: "camera.viewfinder")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.6))
    }
  }

  @ViewBuilder private var headerText: some View {
    switch context {
    case .reading:
      Text("Reading selection…")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.white.opacity(0.55))
    case .selection(let text, let fromClipboard):
      Text(fromClipboard
        ? "Clipboard: \u{201C}\(Self.preview(text))\u{201D}"
        : "Selection: \u{201C}\(Self.preview(text))\u{201D}")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.white.opacity(0.75))
        .lineLimit(1)
        .truncationMode(.tail)
    case .nothingSelected:
      Text("Nothing selected \u{2014} writes new text")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Self.warning)
    case .screenshot:
      Text("Reads the selection from a screenshot")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.white.opacity(0.55))
    }
  }

  private static let warning = Color(red: 1.0, green: 0.78, blue: 0.35)

  /// First stretch of the selection on one line; the view truncates the rest.
  private static func preview(_ text: String) -> String {
    String(text.prefix(200)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  // MARK: Rows

  /// Editing actions mean little without text to edit; they stay clickable but step back.
  private func isMuted(_ action: QuickAction) -> Bool {
    isTyping || (context == .nothingSelected && action.isEdit)
  }

  private func actionRow(index: Int, action: QuickAction) -> some View {
    let highlighted = !isTyping && index == selectedIndex
    let muted = isMuted(action) && !highlighted
    return Button {
      onSelect(index)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: action.kind.symbolName)
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.white.opacity(muted ? 0.35 : 0.7))
          .frame(width: 16, alignment: .center)
        Text(action.text)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.white.opacity(muted ? 0.45 : 1))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
        if index < 9 {
          Text("\u{2303}\(index + 1)")
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundColor(.white.opacity(highlighted ? 0.8 : 0.35))
            .fixedSize()
        }
      }
      .padding(.horizontal, 8)
      .frame(height: QuickActionCardMetrics.rowHeight)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(highlighted ? Color.white.opacity(0.16) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(action.text)
    .accessibilityLabel("Quick action \(index + 1): \(action.text)")
    .accessibilityHint("Control-\(index + 1)")
    .pointerCursorOnHover()
  }

  /// A bare digit, not ⌃digit like the quick actions: the picker has no field to type into, and
  /// one key per choice is what a dictation microphone's buttons can send.
  private func templateChoiceRow(_ index: Int) -> some View {
    let highlighted = index == templateChoiceIndex
    let name = templateChoices[index]
    return Button {
      onChooseTemplate(index)
    } label: {
      HStack(spacing: 8) {
        Text(index < 9 ? "\(index + 1)" : "")
          .font(.system(size: 10, weight: .semibold).monospacedDigit())
          .foregroundColor(.white.opacity(highlighted ? 0.95 : 0.55))
          .frame(width: 16, height: 16)
          .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .strokeBorder(Color.white.opacity(highlighted ? 0.55 : 0.2), lineWidth: 1)
              .opacity(index < 9 ? 1 : 0)
          )
        Text(name)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.white.opacity(highlighted ? 1 : 0.8))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
        if highlighted {
          Text("\u{21A9}")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.6))
        }
      }
      .padding(.horizontal, 8)
      .frame(height: QuickActionCardMetrics.rowHeight)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(highlighted ? Color.white.opacity(0.16) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(name)
    .accessibilityLabel("Template \(index + 1): \(name)")
    .accessibilityHint(index < 9 ? "\(index + 1)" : "")
    .pointerCursorOnHover()
  }

  private var fieldRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "keyboard")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.white.opacity(isTyping ? 1 : 0.55))
        .frame(width: 16, alignment: .center)
      TextField(QuickActionCardMetrics.typeFieldPlaceholder, text: $typedText)
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
        .focused($fieldFocused)
        .onSubmit(submit)
        .onExitCommand(perform: onDismiss)
        .accessibilityLabel("Type your own instruction")
    }
    .padding(.horizontal, 8)
    .frame(height: QuickActionCardMetrics.rowHeight)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(isTyping ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
    )
    .onAppear {
      // The panel takes key status as the card appears; focus on the next turn.
      DispatchQueue.main.async { fieldFocused = true }
    }
  }

  /// ↩ does what the footer says: the typed text, else the highlighted entry, else the speech.
  private func submit() {
    if isTyping {
      onSubmitTyped()
    } else if let selectedIndex {
      onSelect(selectedIndex)
    } else {
      onConfirm()
    }
  }

  // MARK: Footer

  private var footerLabel: String {
    if showsPicker { return String(localized: "Press a number to choose") }
    if isTyping { return String(localized: "\u{21A9} runs what you typed") }
    if let selectedIndex, actions.indices.contains(selectedIndex) {
      return String(localized: "\u{21A9} runs \u{201C}\(actions[selectedIndex].text)\u{201D}")
    }
    if showsTemplateHeader, templateEnabled, let templateName {
      return String(localized: "\u{21A9} formats it as \u{201C}\(templateName)\u{201D}")
    }
    return String(localized: "Speak your instruction")
  }

  private var footer: some View {
    HStack(spacing: 8) {
      PillCircleButton(
        symbolName: "xmark", foreground: .white, background: Color(white: 0.28),
        accessibilityLabel: "Discard recording", action: onCancel)
      LevelBarsView(levels: levels)
      Text(footerLabel)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if !isTyping && selectedIndex == nil && !showsPicker {
        Text("\u{21A9}")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.white.opacity(0.4))
      }
      PillCircleButton(
        symbolName: "checkmark", foreground: .black, background: .white,
        accessibilityLabel: isTyping ? ("Run typed instruction" as LocalizedStringKey) : "Stop and process",
        action: onConfirm)
    }
    .padding(.horizontal, 4)
    .frame(height: QuickActionCardMetrics.footerHeight)
  }
}

struct RecordingIndicatorView: View {
  @ObservedObject var model: RecordingIndicatorModel
  let onCancel: () -> Void
  let onConfirm: () -> Void
  let onTogglePause: () -> Void
  let onCycleSpeed: () -> Void
  let onSkip: (TimeInterval) -> Void
  let onSeek: (TimeInterval) -> Void
  let onQuickAction: (Int) -> Void
  let onSubmitTyped: () -> Void
  let onDismissQuickActions: () -> Void
  let onToggleTemplate: () -> Void
  let onChooseTemplate: (Int) -> Void

  /// Seconds the ⏪ / ⏩ buttons jump.
  static let skipInterval: TimeInterval = 10

  static func timeLabel(_ seconds: TimeInterval) -> String {
    let whole = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", whole / 60, whole % 60)
  }

  /// The Dictate Prompt card while recording with quick actions, else the pill. The card holds
  /// the recording controls itself, so it replaces the pill instead of stacking on it.
  static func panelSize(
    phase: RecordingIndicatorPhase,
    quickActions: [QuickAction],
    showsQuickActions: Bool,
    hasTemplate: Bool = false,
    templateChoiceCount: Int = 0
  ) -> CGSize {
    let cardVisible = showsQuickActions && phase == .recording
      && (!quickActions.isEmpty || hasTemplate)
    guard cardVisible else { return pillSize(for: phase) }
    // A template recording lists only the picker's templates, and never the field.
    let height = hasTemplate
      ? QuickActionCardMetrics.height(count: templateChoiceCount, field: false)
      : QuickActionCardMetrics.height(count: quickActions.count)
    return CGSize(width: QuickActionCardMetrics.width, height: height)
  }

  /// The pill grows with a status word so the user can tell listening from transcribing
  /// without decoding icons (Wispr Flow Bar / Superwhisper parity).
  static func pillSize(for phase: RecordingIndicatorPhase) -> CGSize {
    switch phase {
    case .recording: return CGSize(width: 218, height: 40)
    case .processing: return CGSize(width: 168, height: 40)
    case .speaking: return CGSize(width: 420, height: 40)
    }
  }

  var body: some View {
    let pill = Self.pillSize(for: model.phase)
    let panel = Self.panelSize(
      phase: model.phase,
      quickActions: model.quickActions,
      showsQuickActions: model.quickActionsVisible,
      hasTemplate: model.templateName != nil,
      templateChoiceCount: model.visibleTemplateChoices.count)
    Group {
      if panel != pill {
        QuickActionCardView(
          actions: model.quickActions,
          selectedIndex: model.quickActionIndex,
          context: model.quickActionContext,
          templateName: model.templateName,
          templateEnabled: model.templateEnabled,
          onToggleTemplate: onToggleTemplate,
          templateChoices: model.visibleTemplateChoices,
          templateChoiceIndex: model.templateChoiceIndex,
          onChooseTemplate: onChooseTemplate,
          levels: model.levels,
          typedText: $model.typedPrompt,
          onSelect: onQuickAction,
          onSubmitTyped: onSubmitTyped,
          onDismiss: onDismissQuickActions,
          onCancel: onCancel,
          onConfirm: onConfirm
        )
        .frame(width: panel.width, height: panel.height)
      } else {
        pillBody(size: pill)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .environment(\.colorScheme, .dark)
  }

  private func pillBody(size: CGSize) -> some View {
    HStack(spacing: 8) {
      switch model.phase {
      case .recording:
        PillCircleButton(
          symbolName: "xmark", foreground: .white, background: Color(white: 0.28),
          accessibilityLabel: "Discard recording", action: onCancel)
        LevelBarsView(levels: model.levels)
        Text(model.statusLabel)
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.white)
        PillCircleButton(
          symbolName: "checkmark", foreground: .black, background: .white,
          accessibilityLabel: "Stop and process", action: onConfirm)
      case .processing:
        PillCircleButton(
          symbolName: "xmark", foreground: .white, background: Color(white: 0.28),
          accessibilityLabel: "Cancel processing", action: onCancel)
        SpinnerView()
        Text(model.statusLabel)
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.white)
      case .speaking:
        PillCircleButton(
          symbolName: "xmark", foreground: .white, background: Color(white: 0.28),
          accessibilityLabel: "Stop reading aloud", action: onCancel)
        PillCircleButton(
          symbolName: "gobackward.10", foreground: .white, background: Color(white: 0.28),
          accessibilityLabel: "Back 10 seconds", action: { onSkip(-Self.skipInterval) })
        PillCircleButton(
          symbolName: model.isPaused ? "play.fill" : "pause.fill", foreground: .black, background: .white,
          accessibilityLabel: (model.isBuffering && !model.isPaused)
            ? ("Loading more audio — click to pause" as LocalizedStringKey)
            : (model.isPaused ? "Resume reading aloud" : "Pause reading aloud"),
          isBusy: model.isBuffering && !model.isPaused,
          action: onTogglePause)
        PillCircleButton(
          symbolName: "goforward.10", foreground: .white, background: Color(white: 0.28),
          accessibilityLabel: "Forward 10 seconds", action: { onSkip(Self.skipInterval) })
        ScrubberView(model: model, onSeek: onSeek)
        if model.isBuffering && !model.isPaused {
          Text("Loading…")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundColor(.white.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
        } else {
          Text("\(Self.timeLabel(model.scrubPosition ?? model.position)) / \(Self.timeLabel(model.duration))")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundColor(.white.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
        }
        SpeedButton(speed: model.speed, action: onCycleSpeed)
      }
    }
    .padding(.horizontal, 8)
    .frame(width: size.width, height: size.height)
    .background(Capsule().fill(Color.black.opacity(0.92)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityTitle)
  }

  private var accessibilityTitle: String {
    switch model.phase {
    case .recording, .processing: return model.statusLabel
    case .speaking:
      if model.isPaused { return String(localized: "Read Aloud paused") }
      if model.isBuffering { return String(localized: "Reading aloud — loading") }
      return String(localized: "Reading aloud")
    }
  }
}

// MARK: - Window Plumbing

/// Borderless, non-activating panel so button clicks never steal focus from the
/// app the user is dictating into. It takes key status only while the user types a
/// Dictate Prompt instruction (while the quick-action list is up) — non-activating, so
/// the target app stays frontmost.
private final class RecordingIndicatorPanel: NSPanel {
  var acceptsKeyInput = false
  /// ⌃1–9 while the card has key focus. Returns true when the digit picked an entry.
  var onControlDigit: ((Int) -> Bool)?
  /// A bare 1–9 while the card has key focus. Returns true when it picked a template.
  var onDigit: ((Int) -> Bool)?
  /// ↑ (-1) / ↓ (+1) while the card has key focus. Returns true when it moved the highlight.
  var onArrow: ((Int) -> Bool)?
  /// ↩ while the card has key focus. Returns true when it ran the highlighted entry.
  var onReturn: (() -> Bool)?
  /// ⇥ while the card has key focus. Returns true when it switched the dictation template.
  var onTab: (() -> Bool)?
  override var canBecomeKey: Bool { acceptsKeyInput }
  override var canBecomeMain: Bool { false }

  /// Caught here rather than in SwiftUI: the text field would otherwise take ⌃digit as input.
  override func sendEvent(_ event: NSEvent) {
    // Only the template picker takes a bare digit, and it shows no field, so nothing is lost.
    if event.type == .keyDown,
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      let characters = event.charactersIgnoringModifiers, characters.count == 1,
      let digit = Int(characters), (1...9).contains(digit),
      onDigit?(digit) == true
    {
      return
    }
    if event.type == .keyDown,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
      let characters = event.charactersIgnoringModifiers, characters.count == 1,
      let digit = Int(characters), (1...9).contains(digit),
      onControlDigit?(digit) == true
    {
      return
    }
    // Also caught here: the text field's editor consumes ↑/↓ as caret moves before SwiftUI's
    // onKeyPress sees them, so the highlight never moved and ↩ stopped with the (empty) speech.
    if event.type == .keyDown,
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      let delta = [126: -1, 125: 1][event.keyCode],
      (firstResponder as? NSTextView)?.hasMarkedText() != true,
      onArrow?(delta) == true
    {
      return
    }
    // ↩ on a highlighted entry is decided here from the model, not by the field's onSubmit:
    // that closure kept a stale "nothing highlighted" and stopped with the (empty) speech.
    if event.type == .keyDown,
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      event.keyCode == 36 || event.keyCode == 76,
      (firstResponder as? NSTextView)?.hasMarkedText() != true,
      onReturn?() == true
    {
      return
    }
    // ⇥ would only move focus out of the field; with a template bound it switches the template.
    if event.type == .keyDown,
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      event.keyCode == 48,
      (firstResponder as? NSTextView)?.hasMarkedText() != true,
      onTab?() == true
    {
      return
    }
    super.sendEvent(event)
  }
}

/// Lets the pill's buttons react to the first click even though the panel never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Manager

/// Owns the floating indicator panel. Main-thread only.
final class RecordingIndicatorManager {
  static let shared = RecordingIndicatorManager()

  /// Discard the current recording / cancel processing. Set by MenuBarController.
  var onCancel: (() -> Void)?
  /// Stop recording and start processing. Set by MenuBarController.
  var onConfirm: (() -> Void)?
  /// Read Aloud: pause or resume playback. Set by MenuBarController.
  var onTogglePause: (() -> Void)?
  /// Read Aloud: step to the next playback speed. Set by MenuBarController.
  var onCycleSpeed: (() -> Void)?
  /// Read Aloud: jump the playhead by a signed number of seconds. Set by MenuBarController.
  var onSkip: ((TimeInterval) -> Void)?
  /// Read Aloud: move the playhead to an absolute position in seconds. Set by MenuBarController.
  var onSeek: ((TimeInterval) -> Void)?
  /// Dictate Prompt: the user switched the bound dictation template on (true) or off. Set by
  /// MenuBarController, which keeps the choice on the recording.
  var onTemplateToggled: ((Bool) -> Void)?
  /// Template shortcut with several templates: the picker changed which template stopping applies
  /// (a digit, ↑/↓, ↩ or a click). The index is into the names passed to `showQuickActions`.
  var onTemplateChoice: ((Int) -> Void)?
  /// Dictate Prompt: the user clicked a quick action. The index is into `quickActions`.
  var onQuickAction: ((Int) -> Void)?
  /// Dictate Prompt: the user pressed ↩ in the field. Carries the trimmed, non-empty text.
  var onTypedPrompt: ((String) -> Void)?

  private(set) var isVisible = false

  private let model = RecordingIndicatorModel()
  private var panel: RecordingIndicatorPanel?
  /// Observers that re-raise the pill when another app or Space comes forward.
  private var frontObservers: [NSObjectProtocol] = []

  private enum Constants {
    static let bottomMargin: CGFloat = 28
    static let fadeDuration: TimeInterval = 0.18
    /// averagePower(dB) range mapped onto bar height 0…1.
    static let silenceFloorDB: Float = -48
    static let loudCeilingDB: Float = -14
  }

  private init() {}

  // MARK: Phase transitions

  func showRecording(label: String = String(localized: "Listening")) {
    model.resetLevels()
    model.statusLabel = label
    model.phase = .recording
    orderFrontPanel()
  }

  /// Switches to the spinner. When the pill is already on screen (Dictate / Dictate
  /// Prompt hand off from recording) it just shrinks to the processing size. For flows
  /// with no recording phase (Read Aloud / TTS) pass `summonIfNeeded: true` to pull the
  /// processing pill up directly. Otherwise it stays a no-op so pill-less flows
  /// (e.g. file-based processing) don't suddenly grow a pill.
  func showProcessing(summonIfNeeded: Bool = false, label: String = String(localized: "Transcribing")) {
    model.statusLabel = label
    model.phase = .processing
    if isVisible, let panel {
      position(panel)
    } else if summonIfNeeded {
      orderFrontPanel()
    }
  }

  /// Shows the Read Aloud transport pill, or refreshes its pause / speed state when already
  /// on screen. Summons the pill directly — playback may start without a processing phase on
  /// screen (e.g. Read Aloud triggered while the pill was hidden by another state).
  func showSpeaking(isPaused: Bool, speed: ReadAloudSpeed) {
    model.isPaused = isPaused
    model.speed = speed
    let phaseChanged = model.phase != .speaking
    if phaseChanged {
      model.scrubPosition = nil
      model.isBuffering = false
    }
    model.phase = .speaking
    if isVisible, let panel {
      if phaseChanged { position(panel) }
    } else {
      orderFrontPanel()
    }
  }

  /// Feeds the scrubber. Ignored while the user is dragging it, so the knob follows the mouse.
  func updateProgress(position: TimeInterval, duration: TimeInterval, received: TimeInterval) {
    guard model.phase == .speaking else { return }
    model.duration = duration
    model.received = received
    if model.scrubPosition == nil { model.position = position }
  }

  /// Read Aloud: the player's queue ran dry (or refilled) while the stream is still open.
  func updateBuffering(_ isBuffering: Bool) {
    guard model.phase == .speaking else { return }
    model.isBuffering = isBuffering
  }

  func hide() {
    releaseKeyFocus()
    stopKeepingInFront()
    guard isVisible, let panel else {
      isVisible = false
      return
    }
    isVisible = false
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Constants.fadeDuration
      panel.animator().alphaValue = 0
    }) { [weak self] in
      // A show within the fade sets isVisible again; ordering out then would
      // hide the pill that just came back.
      guard let self, !self.isVisible else { return }
      panel.orderOut(nil)
    }
  }

  /// Grows the pill into the Dictate Prompt card. Nothing starts highlighted, and the field
  /// takes keyboard focus, so the user can type right away. `templateName`: the dictation template
  /// bound to the app underneath; the card then shows even with no quick actions, so the header can
  /// say what stopping does. `templateChoices`: with two or more, the card opens the template
  /// picker on `templateChoiceIndex`, whose name `templateName` must be.
  func showQuickActions(
    _ actions: [QuickAction], context: QuickActionContext, templateName: String? = nil,
    templateChoices: [String] = [], templateChoiceIndex: Int = 0
  ) {
    model.quickActions = actions
    model.quickActionIndex = nil
    model.quickActionContext = context
    model.typedPrompt = ""
    model.templateName = templateName
    model.templateEnabled = true
    model.templateChoices = templateChoices
    model.templateChoiceIndex = templateChoices.indices.contains(templateChoiceIndex)
      ? templateChoiceIndex : 0
    model.templatePickerOpen = templateChoices.count > 1
    model.quickActionsVisible = !actions.isEmpty || templateName != nil
    if isVisible, let panel {
      position(panel)
      takeKeyFocusIfListed(panel)
    }
  }

  func hideQuickActions() {
    releaseKeyFocus()
    model.typedPrompt = ""
    guard model.quickActionsVisible || !model.quickActions.isEmpty else { return }
    model.quickActionsVisible = false
    model.quickActions = []
    model.templateName = nil
    model.templateChoices = []
    model.templatePickerOpen = false
    model.quickActionIndex = nil
    if isVisible, let panel { position(panel) }
  }

  /// The selection arrives after the card is up (the ⌘C poll); the header follows it.
  func updateQuickActionContext(_ context: QuickActionContext) {
    guard model.quickActionsVisible else { return }
    model.quickActionContext = context
  }

  /// ↓ from nothing lands on the first entry, ↑ on the last; after that it wraps.
  func moveQuickActionSelection(by delta: Int) {
    guard model.quickActionsVisible, !model.quickActions.isEmpty else { return }
    let count = model.quickActions.count
    let next = model.quickActionIndex.map { (($0 + delta) % count + count) % count }
      ?? (delta > 0 ? 0 : count - 1)
    model.quickActionIndex = next
    DebugLogger.log("QUICK-ACTIONS: Highlight → entry \(next + 1)")
  }

  /// Tab or a click on the template header: switch the bound template off or back on. The choice
  /// lives on the recording (`onTemplateToggled`), not here — the card is gone by the time the
  /// finished audio is processed.
  private func toggleTemplate() {
    guard let name = model.templateName else { return }
    model.templateEnabled.toggle()
    closeTemplatePicker()
    DebugLogger.log(
      "DICTATION-TEMPLATE: \(model.templateEnabled ? "Applying" : "Not applying") \(name) (Tab)")
    onTemplateToggled?(model.templateEnabled)
  }

  /// Highlights a template in the picker and tells the recording; `close` collapses the list into
  /// the "Praxisnotiz · Tab: Normal" header.
  private func chooseTemplate(_ index: Int, close: Bool) {
    guard model.templateChoices.indices.contains(index) else { return }
    model.templateChoiceIndex = index
    model.templateName = model.templateChoices[index]
    model.templateEnabled = true
    DebugLogger.log("DICTATION-TEMPLATE: Picker → choice \(index + 1)\(close ? ", closed" : "")")
    onTemplateChoice?(index)
    if close { closeTemplatePicker() }
  }

  private func closeTemplatePicker() {
    guard model.templatePickerOpen else { return }
    model.templatePickerOpen = false
    if isVisible, let panel { position(panel) }
  }

  var quickActions: [QuickAction] { model.quickActions }
  var typedPrompt: String {
    model.typedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The app the user was in when the field took focus. Reactivated when the list goes,
  /// so the result pastes there.
  private var keyFocusReturnApp: NSRunningApplication?

  private func takeKeyFocusIfListed(_ panel: RecordingIndicatorPanel) {
    guard model.quickActionsVisible, !panel.acceptsKeyInput else { return }
    keyFocusReturnApp = NSWorkspace.shared.frontmostApplication
    panel.acceptsKeyInput = true
    panel.makeKey()
  }

  private func releaseKeyFocus() {
    guard let panel, panel.acceptsKeyInput else { return }
    let hadKey = panel.isKeyWindow
    panel.acceptsKeyInput = false
    panel.resignKey()
    // Only hand focus back if the user didn't move on to another app meanwhile.
    if hadKey, let app = keyFocusReturnApp, app == NSWorkspace.shared.frontmostApplication {
      app.activate()
    }
    keyFocusReturnApp = nil
  }

  private func submitTyped() {
    let text = typedPrompt
    guard !text.isEmpty else { return }
    onTypedPrompt?(text)
  }

  private func dismissQuickActionsByUser() {
    DebugLogger.log("QUICK-ACTIONS: List hidden — recording continues")
    hideQuickActions()
  }

  /// Feed one metering sample (average power in dB) into the bars.
  func updateLevel(dB: Float) {
    guard isVisible, model.phase == .recording else { return }
    let range = Constants.loudCeilingDB - Constants.silenceFloorDB
    let clamped = max(0, min(1, (dB - Constants.silenceFloorDB) / range))
    // Slight boost so normal speech visibly moves the bars.
    model.pushLevel(CGFloat(pow(clamped, 0.75)))
  }

  // MARK: Panel

  private func orderFrontPanel() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    position(panel)
    panel.alphaValue = 0
    // Re-applied on every show: the panel is reused, and anything that lowers its level once
    // (a stray `window.level = .floating` on the key window) would otherwise stick for good.
    panel.level = .statusBar
    panel.orderFrontRegardless()
    isVisible = true
    takeKeyFocusIfListed(panel)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Constants.fadeDuration
      panel.animator().alphaValue = 1
    }
    startKeepingInFront()
  }

  /// Re-raises the pill while it is visible when another app activates or the Space changes.
  private func startKeepingInFront() {
    guard frontObservers.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter
    let raise: (Notification) -> Void = { [weak self] _ in
      guard let self, self.isVisible, let panel = self.panel else { return }
      panel.orderFrontRegardless()
    }
    frontObservers = [
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: raise),
      center.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: raise),
    ]
  }

  /// Stops re-raising the pill once it is hidden.
  private func stopKeepingInFront() {
    let center = NSWorkspace.shared.notificationCenter
    for observer in frontObservers {
      center.removeObserver(observer)
    }
    frontObservers.removeAll()
  }

  private func makePanel() -> RecordingIndicatorPanel {
    let size = currentPanelSize()
    let panel = RecordingIndicatorPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.ignoresMouseEvents = false

    let view = RecordingIndicatorView(
      model: model,
      onCancel: { [weak self] in self?.onCancel?() },
      onConfirm: { [weak self] in self?.onConfirm?() },
      onTogglePause: { [weak self] in self?.onTogglePause?() },
      onCycleSpeed: { [weak self] in self?.onCycleSpeed?() },
      onSkip: { [weak self] seconds in self?.onSkip?(seconds) },
      onSeek: { [weak self] seconds in self?.onSeek?(seconds) },
      onQuickAction: { [weak self] index in self?.onQuickAction?(index) },
      onSubmitTyped: { [weak self] in self?.submitTyped() },
      onDismissQuickActions: { [weak self] in self?.dismissQuickActionsByUser() },
      onToggleTemplate: { [weak self] in self?.toggleTemplate() },
      onChooseTemplate: { [weak self] index in self?.chooseTemplate(index, close: true) }
    )
    let hostingView = FirstMouseHostingView(rootView: view)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    panel.onControlDigit = { [weak self] digit in
      guard let self, self.model.quickActionsVisible,
        self.model.quickActions.indices.contains(digit - 1)
      else { return false }
      self.onQuickAction?(digit - 1)
      return true
    }
    panel.onDigit = { [weak self] digit in
      guard let self, self.model.quickActionsVisible,
        self.model.visibleTemplateChoices.indices.contains(digit - 1)
      else { return false }
      self.chooseTemplate(digit - 1, close: true)
      return true
    }
    panel.onArrow = { [weak self] delta in
      if let self, self.model.quickActionsVisible, !self.model.visibleTemplateChoices.isEmpty {
        let count = self.model.templateChoices.count
        self.chooseTemplate(((self.model.templateChoiceIndex + delta) % count + count) % count, close: false)
        return true
      }
      guard let self, self.model.quickActionsVisible,
        self.model.typedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return false }
      self.moveQuickActionSelection(by: delta)
      return true
    }
    panel.onReturn = { [weak self] in
      if let self, self.model.quickActionsVisible, self.model.templateName != nil {
        // The picker: ↩ takes the highlighted template and keeps recording. Without it the
        // card has no field to submit, so ↩ stops, as the footer says.
        if !self.model.visibleTemplateChoices.isEmpty {
          self.chooseTemplate(self.model.templateChoiceIndex, close: true)
        } else {
          self.onConfirm?()
        }
        return true
      }
      guard let self, self.model.quickActionsVisible,
        self.model.typedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let index = self.model.quickActionIndex, self.model.quickActions.indices.contains(index)
      else { return false }
      DebugLogger.log("QUICK-ACTIONS: ↩ runs highlighted entry \(index + 1)")
      self.onQuickAction?(index)
      return true
    }
    panel.onTab = { [weak self] in
      guard let self, self.model.quickActionsVisible, self.model.templateName != nil,
        self.model.quickActionContext == .nothingSelected
          || !self.model.visibleTemplateChoices.isEmpty
      else { return false }
      self.toggleTemplate()
      return true
    }
    return panel
  }

  private func currentPanelSize() -> NSSize {
    let size = RecordingIndicatorView.panelSize(
      phase: model.phase,
      quickActions: model.quickActions,
      showsQuickActions: model.quickActionsVisible,
      hasTemplate: model.templateName != nil,
      templateChoiceCount: model.visibleTemplateChoices.count)
    return NSSize(width: size.width, height: size.height)
  }

  /// Centers the panel bottom-center at the size matching the current phase, so the
  /// clickable window area always matches the visible pill.
  private func position(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let size = currentPanelSize()
    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.minY + Constants.bottomMargin
    )
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
  }
}

// MARK: - Pill status words

extension AppState.RecordingMode {
  /// Short enough for the fixed recording pill width (see `pillSize`).
  var pillLabel: String {
    switch self {
    case .transcription, .liveMeeting: return String(localized: "Listening")
    case .prompt: return String(localized: "Prompting")
    }
  }
}

extension AppState.ProcessingMode {
  /// Short enough for the fixed processing pill width (see `pillSize`).
  var pillLabel: String {
    switch self {
    case .transcribing: return String(localized: "Transcribing")
    case .prompting: return String(localized: "Thinking")
    case .ttsProcessing: return String(localized: "Preparing")
    case .splitting, .processingChunks, .merging:
      return isTTSContext ? String(localized: "Preparing") : String(localized: "Transcribing")
    }
  }
}
