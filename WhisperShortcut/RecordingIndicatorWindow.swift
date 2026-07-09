//
//  RecordingIndicatorWindow.swift
//  WhisperShortcut
//
//  A small floating pill at the bottom-center of the screen (Wispr-Flow style) that
//  accompanies the Dictate / Dictate Prompt lifecycle:
//    recording  → live audio-level bars with ✕ (discard) and ✓ (stop & process)
//    processing → spinner with ✕ (cancel)
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
}

final class RecordingIndicatorModel: ObservableObject {
  static let barCount = 10

  @Published var phase: RecordingIndicatorPhase = .recording
  @Published var levels: [CGFloat] = Array(repeating: 0, count: RecordingIndicatorModel.barCount)

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
  @State private var isRotating = false

  var body: some View {
    Circle()
      .trim(from: 0.18, to: 1)
      .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
      .frame(width: 14, height: 14)
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
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(background)
        Image(systemName: symbolName)
          .font(.system(size: 10, weight: .bold))
          .foregroundColor(foreground)
      }
      .frame(width: 24, height: 24)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .onHover { inside in
      if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
  }
}

struct RecordingIndicatorView: View {
  @ObservedObject var model: RecordingIndicatorModel
  let onCancel: () -> Void
  let onConfirm: () -> Void

  /// The pill shrinks while processing — only ✕ and the spinner remain.
  static func pillSize(for phase: RecordingIndicatorPhase) -> CGSize {
    switch phase {
    case .recording: return CGSize(width: 158, height: 40)
    case .processing: return CGSize(width: 72, height: 40)
    }
  }

  var body: some View {
    let size = Self.pillSize(for: model.phase)
    HStack(spacing: 10) {
      switch model.phase {
      case .recording:
        PillCircleButton(
          symbolName: "xmark", foreground: .white, background: Color(white: 0.28),
          accessibilityLabel: "Discard recording", action: onCancel)
        LevelBarsView(levels: model.levels)
        PillCircleButton(
          symbolName: "checkmark", foreground: .black, background: .white,
          accessibilityLabel: "Stop and process", action: onConfirm)
      case .processing:
        PillCircleButton(
          symbolName: "xmark", foreground: .white, background: Color(white: 0.28),
          accessibilityLabel: "Cancel processing", action: onCancel)
        SpinnerView()
          .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 8)
    .frame(width: size.width, height: size.height)
    .background(Capsule().fill(Color.black.opacity(0.92)))
    .environment(\.colorScheme, .dark)
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

  /// Switches to the spinner. No-op when the pill isn't on screen (e.g. TTS or
  /// file-based processing that didn't start from a pill-visible recording).
  func showProcessing() {
    guard isVisible, let panel else { return }
    model.phase = .processing
    position(panel)
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
      onConfirm: { [weak self] in self?.onConfirm?() }
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
