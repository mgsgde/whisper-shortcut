import AppKit
import SwiftUI

/// The live text panel while dictating (plans/active/live-dictate-preview.md, S3).
///
/// Sits just above the recording pill as its child window — so it moves, layers and hides with
/// it, and the pill's own re-raising covers it too — in the same dark card style as the Dictate
/// Prompt card (`RecordingIndicatorWindow.swift`): black at 92 %, 16 pt corners, a hairline
/// border. It is dark in light and dark mode alike, like the pill it belongs to.
///
/// Read-only by design: non-activating, never key, ignores the mouse, no buttons. Focus and every
/// click stay with the app the user dictates into. Text FluidAudio has confirmed is white, the
/// newest part is dimmed (confirmed means "decoded with high confidence", not "final": the pasted
/// text comes from the decode after Stop), and the newest line stays in view; at most ~6 lines
/// show. It appears with the first words, never empty.
final class LiveDictatePanel {
  static let shared = LiveDictatePanel()

  private let model = LiveDictatePanelModel()
  private var panel: NSPanel?
  private(set) var isVisible = false

  private enum Metrics {
    static let width: CGFloat = 560
    /// Room for the caption plus `LiveDictatePanelView.maxTextHeight`. The card itself only grows
    /// as tall as its text; the rest of the frame is transparent and click-through.
    static let height: CGFloat = 170
    /// Gap between the pill's top edge and this panel.
    static let gapAbovePill: CGFloat = 10
    /// Fallback when the pill is not on screen: where its top edge normally is (28 pt margin +
    /// 40 pt pill, `RecordingIndicatorManager`, `RecordingIndicatorView.pillSize`).
    static let fallbackBottomOffset: CGFloat = 28 + 40 + 10
    static let fadeDuration: TimeInterval = 0.18
  }

  private init() {}

  func show() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if let pill = RecordingIndicatorManager.shared.visibleWindow {
      place(panel, above: pill.frame, on: pill.screen)
      if panel.parent !== pill {
        panel.parent?.removeChildWindow(panel)
        pill.addChildWindow(panel, ordered: .above)
      }
    } else {
      place(panel, above: nil, on: NSScreen.main)
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    isVisible = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Metrics.fadeDuration
      panel.animator().alphaValue = 1
    }
  }

  func update(committed: String, tentative: String) {
    model.committed = committed
    model.tentative = tentative
  }

  func hide() {
    guard isVisible, let panel else {
      isVisible = false
      return
    }
    isVisible = false
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Metrics.fadeDuration
      panel.animator().alphaValue = 0
    }) { [weak self] in
      // A show within the fade sets isVisible again; ordering out then would hide the new panel.
      guard let self, !self.isVisible else { return }
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
      self.model.committed = ""
      self.model.tentative = ""
    }
  }

  private func makePanel() -> NSPanel {
    let panel = LiveDictateNSPanel(
      contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false  // the card draws its own; the frame is mostly transparent
    // Same level as the recording pill, so the two stay together above other apps' windows.
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.ignoresMouseEvents = true
    let hostingView = NSHostingView(rootView: LiveDictatePanelView(model: model))
    hostingView.frame = NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height)
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    return panel
  }

  /// Centred over the pill, its bottom edge `gapAbovePill` above the pill's top. Without a pill,
  /// where the pill's top edge normally is.
  private func place(_ panel: NSPanel, above pillFrame: NSRect?, on screen: NSScreen?) {
    guard let screen = screen ?? NSScreen.main else { return }
    let visible = screen.visibleFrame
    let width = min(Metrics.width, visible.width - 32)
    let midX = pillFrame?.midX ?? visible.midX
    let bottom = pillFrame.map { $0.maxY + Metrics.gapAbovePill } ?? visible.minY + Metrics.fallbackBottomOffset
    let origin = NSPoint(x: midX - width / 2, y: bottom)
    panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: Metrics.height)), display: true)
  }
}

/// Never key, never main: the target app keeps the keyboard.
private final class LiveDictateNSPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

final class LiveDictatePanelModel: ObservableObject {
  @Published var committed = ""
  @Published var tentative = ""
}

struct LiveDictatePanelView: View {
  @ObservedObject var model: LiveDictatePanelModel

  static let fontSize: CGFloat = 14
  static let lineSpacing: CGFloat = 3
  /// About six lines of `fontSize` text.
  static let maxTextHeight: CGFloat = 6 * (fontSize * 1.2 + lineSpacing)
  private static let cornerRadius: CGFloat = 16
  private static let bottomID = "live-dictate-bottom"

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) {
        Image(systemName: "text.bubble")
          .font(.system(size: 10, weight: .semibold))
        Text("Live preview — the final text follows after Stop")
          .font(.system(size: 10, weight: .semibold))
          .lineLimit(1)
      }
      // 60 %: the 45 % the pill uses for hints is below 4.5:1 contrast at this size.
      .foregroundColor(.white.opacity(0.6))
      .accessibilityHidden(true)

      // Hugs short text; past ~6 lines it scrolls and keeps the newest line in view.
      ViewThatFits(in: .vertical) {
        transcript
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) {
            transcript
            Color.clear.frame(height: 0).id(Self.bottomID)
          }
          .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
          .onChange(of: model.committed) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
          .onChange(of: model.tentative) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
      }
      .frame(maxHeight: Self.maxTextHeight, alignment: .bottom)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .fill(Color.black.opacity(0.92))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    .padding(.horizontal, 8)
    .padding(.bottom, 4)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    // One element whose value is the visible text, so VoiceOver can read it on demand. No live
    // announcements: speech output while dictating would talk over the user and could end up in
    // the recording.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Live dictation preview")
    .accessibilityValue(Text(verbatim: accessibilityText))
  }

  private var accessibilityText: String {
    [model.committed, model.tentative].filter { !$0.isEmpty }.joined(separator: " ")
  }

  private var transcript: some View {
    styledText
      .font(.system(size: Self.fontSize))
      .lineSpacing(Self.lineSpacing)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// Confirmed text in white, the newest part dimmed, as one flowing paragraph.
  private var styledText: Text {
    let committed = Text(verbatim: model.committed).foregroundColor(.white)
    guard !model.tentative.isEmpty else { return committed }
    let separator = model.committed.isEmpty ? "" : " "
    return committed + Text(verbatim: separator + model.tentative).foregroundColor(.white.opacity(0.55))
  }
}
