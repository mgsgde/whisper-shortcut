//
//  RecordingIndicatorWindow.swift
//  WhisperShortcut
//
//  A small floating pill at the bottom-center of the screen (Wispr-Flow style) that
//  accompanies the Dictate / Dictate Prompt lifecycle:
//    recording  → live audio-level bars with ✕ (discard) and ✓ (stop & process);
//                 Dictate Prompt also shows a quick-action list directly above the pill
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
  /// so Dictate, Dictate Prompt and Voice Feedback no longer all read "Listening"/"Transcribing".
  @Published var statusLabel = "Listening"
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
  @Published var quickActionIndex = 0
  @Published var quickActionsVisible = false
  /// Dictate Prompt: what the user typed into the field under the list. Non-empty text
  /// replaces the spoken instruction.
  @Published var typedPrompt = ""

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
  let accessibilityLabel: String
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

private enum QuickActionListMetrics {
  static let rowHeight: CGFloat = 28
  static let verticalPadding: CGFloat = 6
  static let gap: CGFloat = 4
  /// Wide enough to type a real instruction into the field.
  static let width: CGFloat = 360

  static let typeFieldPlaceholder = "Type an instruction, or just speak"

  /// `count` quick actions plus the trailing text field.
  static func height(count: Int) -> CGFloat {
    CGFloat(count + 1) * rowHeight + verticalPadding * 2
  }
}

/// Quick actions plus a text field that has keyboard focus from the start: typing goes
/// straight in. While the field is empty, ↑/↓, ↩ and 1–5 drive the list as before.
private struct QuickActionListView: View {
  let actions: [QuickAction]
  let selectedIndex: Int
  @Binding var typedText: String
  let onSelect: (Int) -> Void
  let onSubmitTyped: () -> Void
  let onMove: (Int) -> Void
  let onDismiss: () -> Void

  @FocusState private var fieldFocused: Bool

  private var isTyping: Bool { !typedText.isEmpty }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
        let highlighted = !isTyping && index == selectedIndex
        Button {
          onSelect(index)
        } label: {
          HStack(spacing: 8) {
            Text("\(index + 1)")
              .font(.system(size: 11, weight: .semibold).monospacedDigit())
              .foregroundColor(.white.opacity(highlighted ? 1 : 0.55))
              .frame(width: 14, alignment: .trailing)
            Text(action.text)
              .font(.system(size: 12, weight: .medium))
              .foregroundColor(.white.opacity(isTyping ? 0.55 : 1))
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 8)
          .frame(height: QuickActionListMetrics.rowHeight)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(highlighted ? Color.white.opacity(0.16) : Color.clear)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.text)
        .accessibilityLabel("Quick action \(index + 1): \(action.text)")
        .pointerCursorOnHover()
      }
      fieldRow
    }
    .padding(.vertical, QuickActionListMetrics.verticalPadding)
    .padding(.horizontal, 4)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.black.opacity(0.92))
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Dictate Prompt quick actions")
  }

  private var fieldRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "keyboard")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.white.opacity(isTyping ? 1 : 0.55))
        .frame(width: 14, alignment: .trailing)
      TextField(QuickActionListMetrics.typeFieldPlaceholder, text: $typedText)
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
        .focused($fieldFocused)
        .onSubmit {
          if isTyping { onSubmitTyped() } else { onSelect(selectedIndex) }
        }
        .onExitCommand(perform: onDismiss)
        .onKeyPress(.upArrow) { moveIfEmpty(-1) }
        .onKeyPress(.downArrow) { moveIfEmpty(1) }
        .onChange(of: typedText) { old, new in
          // A lone digit typed into the empty field picks that entry, as the number keys
          // always did. Anything longer is the user's own instruction.
          guard old.isEmpty, new.count == 1, let digit = Int(new),
                actions.indices.contains(digit - 1) else { return }
          typedText = ""
          onSelect(digit - 1)
        }
        .accessibilityLabel("Type your own instruction")
      if isTyping {
        Text("↩")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.white.opacity(0.55))
      }
    }
    .padding(.horizontal, 8)
    .frame(height: QuickActionListMetrics.rowHeight)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isTyping ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
    )
    .onAppear {
      // The panel takes key status as the list appears; focus on the next turn.
      DispatchQueue.main.async { fieldFocused = true }
    }
  }

  private func moveIfEmpty(_ delta: Int) -> KeyPress.Result {
    guard !isTyping else { return .ignored }
    onMove(delta)
    return .handled
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
  let onMoveQuickAction: (Int) -> Void
  let onDismissQuickActions: () -> Void

  /// Seconds the ⏪ / ⏩ buttons jump.
  static let skipInterval: TimeInterval = 10

  static func timeLabel(_ seconds: TimeInterval) -> String {
    let whole = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", whole / 60, whole % 60)
  }

  /// Pill plus the quick-action list stacked above it. The list only contributes height
  /// while recording, so processing and playback stay the pill's own size.
  static func panelSize(
    phase: RecordingIndicatorPhase,
    quickActions: [QuickAction],
    showsQuickActions: Bool
  ) -> CGSize {
    let pill = pillSize(for: phase)
    let listVisible = showsQuickActions && phase == .recording && !quickActions.isEmpty
    guard listVisible else { return pill }
    let listWidth = max(pill.width, QuickActionListMetrics.width)
    let listHeight = QuickActionListMetrics.height(count: quickActions.count)
    return CGSize(
      width: max(pill.width, listWidth),
      height: pill.height + listHeight + QuickActionListMetrics.gap)
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
      showsQuickActions: model.quickActionsVisible)
    let showsList = panel.height > pill.height
    VStack(spacing: showsList ? QuickActionListMetrics.gap : 0) {
      if showsList {
        QuickActionListView(
          actions: model.quickActions,
          selectedIndex: model.quickActionIndex,
          typedText: $model.typedPrompt,
          onSelect: onQuickAction,
          onSubmitTyped: onSubmitTyped,
          onMove: onMoveQuickAction,
          onDismiss: onDismissQuickActions
        )
        .frame(width: panel.width)
      }
      pillBody(size: pill)
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
            ? "Loading more audio — click to pause"
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
      if model.isPaused { return "Read Aloud paused" }
      if model.isBuffering { return "Reading aloud — loading" }
      return "Reading aloud"
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
  override var canBecomeKey: Bool { acceptsKeyInput }
  override var canBecomeMain: Bool { false }
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
  /// Dictate Prompt: the user clicked a quick action. The index is into `quickActions`.
  var onQuickAction: ((Int) -> Void)?
  /// Dictate Prompt: the user pressed ↩ in the field. Carries the trimmed, non-empty text.
  var onTypedPrompt: ((String) -> Void)?

  private(set) var isVisible = false

  private let model = RecordingIndicatorModel()
  private var panel: RecordingIndicatorPanel?

  private enum Constants {
    static let bottomMargin: CGFloat = 28
    static let fadeDuration: TimeInterval = 0.18
    /// averagePower(dB) range mapped onto bar height 0…1.
    static let silenceFloorDB: Float = -48
    static let loudCeilingDB: Float = -14
  }

  private init() {}

  // MARK: Phase transitions

  func showRecording(label: String = "Listening") {
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
  func showProcessing(summonIfNeeded: Bool = false, label: String = "Transcribing") {
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
    guard isVisible, let panel else {
      isVisible = false
      return
    }
    isVisible = false
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Constants.fadeDuration
      panel.animator().alphaValue = 0
    }) {
      panel.orderOut(nil)
    }
  }

  /// Shows the Dictate Prompt quick-action list above the pill. Entry 1 starts highlighted
  /// and the field under it takes keyboard focus, so the user can type right away.
  func showQuickActions(_ actions: [QuickAction]) {
    model.quickActions = actions
    model.quickActionIndex = 0
    model.typedPrompt = ""
    model.quickActionsVisible = !actions.isEmpty
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
    model.quickActionIndex = 0
    if isVisible, let panel { position(panel) }
  }

  func moveQuickActionSelection(by delta: Int) {
    guard model.quickActionsVisible, !model.quickActions.isEmpty else { return }
    let count = model.quickActions.count
    let index = model.quickActionIndex
    model.quickActionIndex = ((index + delta) % count + count) % count
  }

  var quickActions: [QuickAction] { model.quickActions }
  var quickActionIndex: Int { model.quickActionIndex }
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
    panel.orderFront(nil)
    isVisible = true
    takeKeyFocusIfListed(panel)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Constants.fadeDuration
      panel.animator().alphaValue = 1
    }
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
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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
      onMoveQuickAction: { [weak self] delta in self?.moveQuickActionSelection(by: delta) },
      onDismissQuickActions: { [weak self] in self?.dismissQuickActionsByUser() }
    )
    let hostingView = FirstMouseHostingView(rootView: view)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    return panel
  }

  private func currentPanelSize() -> NSSize {
    let size = RecordingIndicatorView.panelSize(
      phase: model.phase,
      quickActions: model.quickActions,
      showsQuickActions: model.quickActionsVisible)
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
    case .transcription, .liveMeeting: return "Listening"
    case .prompt: return "Prompting"
    case .voiceFeedback: return "Feedback"
    }
  }
}

extension AppState.ProcessingMode {
  /// Short enough for the fixed processing pill width (see `pillSize`).
  var pillLabel: String {
    switch self {
    case .transcribing: return "Transcribing"
    case .prompting, .contextEditing: return "Thinking"
    case .ttsProcessing: return "Preparing"
    case .splitting, .processingChunks, .merging:
      return isTTSContext ? "Preparing" : "Transcribing"
    }
  }
}
