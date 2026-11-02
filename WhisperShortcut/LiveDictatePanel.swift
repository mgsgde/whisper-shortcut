import AppKit
import SwiftUI

/// The live text panel while dictating (plans/active/live-dictate-preview.md, S3).
///
/// Sits just above the recording pill, bottom center, in the same dark card style as the Dictate
/// Prompt card (`RecordingIndicatorWindow.swift`): black at 92 %, 16 pt corners, a hairline
/// border. It is dark in light and dark mode alike, like the pill it belongs to.
///
/// Read-only by design: non-activating, never key, ignores the mouse, no buttons. Focus and every
/// click stay with the app the user dictates into. Confirmed words are white, the tail that may
/// still change is dimmed, and the newest line stays in view; at most ~6 lines show.
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
    /// The recording pill sits 28 pt above the bottom of the visible frame and is 40 pt tall
    /// (`RecordingIndicatorManager`, `RecordingIndicatorView.pillSize`); 10 pt gap above it.
    static let bottomOffset: CGFloat = 28 + 40 + 10
    static let fadeDuration: TimeInterval = 0.18
  }

  private init() {}

  func show() {
    model.committed = ""
    model.tentative = ""
    let panel = self.panel ?? makePanel()
    self.panel = panel
    position(panel)
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
      panel.orderOut(nil)
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

  private func position(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let width = min(Metrics.width, visible.width - 32)
    let origin = NSPoint(x: visible.midX - width / 2, y: visible.minY + Metrics.bottomOffset)
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

  private var isEmpty: Bool { model.committed.isEmpty && model.tentative.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) {
        Image(systemName: "text.bubble")
          .font(.system(size: 10, weight: .semibold))
        Text("Live preview — the final text follows after Stop")
          .font(.system(size: 10, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundColor(.white.opacity(0.45))

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
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Live dictation preview")
  }

  @ViewBuilder
  private var transcript: some View {
    Group {
      if isEmpty {
        Text("Your words appear here a few seconds after you start speaking.")
          .foregroundColor(.white.opacity(0.45))
      } else {
        styledText
      }
    }
    .font(.system(size: Self.fontSize))
    .lineSpacing(Self.lineSpacing)
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// Confirmed words in white, the still-changing tail dimmed, as one flowing paragraph.
  private var styledText: Text {
    let committed = Text(verbatim: model.committed).foregroundColor(.white)
    guard !model.tentative.isEmpty else { return committed }
    let separator = model.committed.isEmpty ? "" : " "
    return committed + Text(verbatim: separator + model.tentative).foregroundColor(.white.opacity(0.55))
  }
}
