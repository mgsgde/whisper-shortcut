//
//  RecordingIndicatorWindow.swift
//  WhisperShortcut
//
//  A small floating pill at the bottom-center of the screen (Wispr-Flow style) that
//  accompanies the Dictate / Dictate Prompt lifecycle:
//    recording  → live audio-level bars with ✕ (discard) and ✓ (stop & process)
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
  @Published var levels: [CGFloat] = Array(repeating: 0, count: RecordingIndicatorModel.barCount)
  /// `.speaking` only: whether playback is paused.
  @Published var isPaused = false
  /// `.speaking` only: the player ran out of audio and is waiting for the next synthesized chunk.
  @Published var isBuffering = false
  /// `.speaking` only: the rate currently applied to playback.
  @Published var speed: ReadAloudSpeed = SettingsDefaults.readAloudSpeed
  /// `.speaking` only: playhead and received audio, in seconds of source audio.
  @Published var position: TimeInterval = 0
  @Published var duration: TimeInterval = 0
  /// `.speaking` only: the user is dragging the scrubber; progress updates leave the knob alone.
  @Published var scrubPosition: TimeInterval?

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

/// Thin track with a knob; dragging previews the target and seeks on release.
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
      let knobX = fraction * width
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.25)).frame(height: Metrics.trackHeight)
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
            model.scrubPosition = fraction * model.duration
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

struct RecordingIndicatorView: View {
  @ObservedObject var model: RecordingIndicatorModel
  let onCancel: () -> Void
  let onConfirm: () -> Void
  let onTogglePause: () -> Void
  let onCycleSpeed: () -> Void
  let onSkip: (TimeInterval) -> Void
  let onSeek: (TimeInterval) -> Void

  /// Seconds the ⏪ / ⏩ buttons jump.
  static let skipInterval: TimeInterval = 10

  static func timeLabel(_ seconds: TimeInterval) -> String {
    let whole = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", whole / 60, whole % 60)
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
    let size = Self.pillSize(for: model.phase)
    HStack(spacing: 8) {
      switch model.phase {
      case .recording:
        PillCircleButton(
          symbolName: "xmark", foreground: .white, background: Color(white: 0.28),
          accessibilityLabel: "Discard recording", action: onCancel)
        LevelBarsView(levels: model.levels)
        Text("Listening")
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
        Text("Transcribing")
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
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityTitle)
  }

  private var accessibilityTitle: String {
    switch model.phase {
    case .recording: return "Listening"
    case .processing: return "Transcribing"
    case .speaking:
      if model.isPaused { return "Read Aloud paused" }
      if model.isBuffering { return "Reading aloud — loading" }
      return "Reading aloud"
    }
  }
}

// MARK: - Window Plumbing

/// Borderless, non-activating panel so button clicks never steal focus from the
/// app the user is dictating into.
private final class RecordingIndicatorPanel: NSPanel {
  override var canBecomeKey: Bool { false }
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

  func showRecording() {
    model.resetLevels()
    model.phase = .recording
    orderFrontPanel()
  }

  /// Switches to the spinner. When the pill is already on screen (Dictate / Dictate
  /// Prompt hand off from recording) it just shrinks to the processing size. For flows
  /// with no recording phase (Read Aloud / TTS) pass `summonIfNeeded: true` to pull the
  /// processing pill up directly. Otherwise it stays a no-op so pill-less flows
  /// (e.g. file-based processing) don't suddenly grow a pill.
  func showProcessing(summonIfNeeded: Bool = false) {
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
  func updateProgress(position: TimeInterval, duration: TimeInterval) {
    guard model.phase == .speaking else { return }
    model.duration = duration
    if model.scrubPosition == nil { model.position = position }
  }

  /// Read Aloud: the player's queue ran dry (or refilled) while the stream is still open.
  func updateBuffering(_ isBuffering: Bool) {
    guard model.phase == .speaking else { return }
    model.isBuffering = isBuffering
  }

  func hide() {
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
      onSeek: { [weak self] seconds in self?.onSeek?(seconds) }
    )
    let hostingView = FirstMouseHostingView(rootView: view)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    return panel
  }

  private func currentPanelSize() -> NSSize {
    let size = RecordingIndicatorView.pillSize(for: model.phase)
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
