//
//  MeetingWindowController.swift
//  WhisperShortcut
//
//  Dedicated window for the Meeting view. One meeting at a time; title shows recording state.
//

import Cocoa
import SwiftUI
import Combine

class MeetingWindowController: NSWindowController {

  private var cancellable: AnyCancellable?
  private var sheetObservers: [NSObjectProtocol] = []
  private var needsDefaultFrame: Bool = false
  private var sheetPresentCount = 0

  private enum Constants {
    static let minWidth: CGFloat = 800
    static let minHeight: CGFloat = 540
    static let maxWidth: CGFloat = 1600
    static let maxHeight: CGFloat = 1600
    static let defaultTitle = "Meeting"
    static let recordingTitle = "🔴 Recording"
    static let frameAutosaveName = "MeetingWindowV1"
  }

  init() {
    let rootView = MeetingRootView()
    let hostingController = NSHostingController(rootView: rootView)
    hostingController.sizingOptions = []

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: Constants.minWidth, height: Constants.minHeight),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )

    window.title = Constants.defaultTitle
    window.contentMinSize = NSSize(width: Constants.minWidth, height: Constants.minHeight)
    window.contentMaxSize = NSSize(width: Constants.maxWidth, height: Constants.maxHeight)
    window.setFrameAutosaveName(Constants.frameAutosaveName)
    window.contentViewController = hostingController

    super.init(window: window)
    shouldCascadeWindows = false
    needsDefaultFrame = !hasStoredFrame()
    window.delegate = self

    cancellable = LiveMeetingTranscriptStore.shared.$isSessionActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] active in
        self?.window?.title = active ? Constants.recordingTitle : Constants.defaultTitle
      }

    sheetObservers = [
      NotificationCenter.default.addObserver(forName: .meetingWindowSheetDidPresent, object: nil, queue: .main) { [weak self] _ in
        guard let self else { return }
        self.sheetPresentCount += 1
      },
      NotificationCenter.default.addObserver(forName: .meetingWindowSheetDidDismiss, object: nil, queue: .main) { [weak self] _ in
        guard let self else { return }
        self.sheetPresentCount = max(0, self.sheetPresentCount - 1)
      }
    ]
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func showWindow() {
    if needsDefaultFrame, let window = window, let screen = NSScreen.main {
      applyDefaultFrame(on: screen, window: window)
      needsDefaultFrame = false
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  private func hasStoredFrame() -> Bool {
    UserDefaults.standard.object(forKey: "NSWindow Frame \(Constants.frameAutosaveName)") != nil
  }

  /// Positions the window to fill the left half of the given screen.
  private func applyDefaultFrame(on screen: NSScreen, window: NSWindow) {
    let usable = screen.visibleFrame
    let w = min(max(usable.width / 2, Constants.minWidth), Constants.maxWidth)
    let h = min(max(usable.height, Constants.minHeight), Constants.maxHeight)
    let frame = NSRect(x: usable.minX, y: usable.minY, width: w, height: h)
    window.setFrame(frame, display: true, animate: false)
  }
}

extension MeetingWindowController: NSWindowDelegate {
  func windowDidResignKey(_ notification: Notification) {
    if NSApp.modalWindow != nil { return }
    if sheetPresentCount > 0 { return }
    // Do not close when a sheet we presented (e.g. Meeting Library) is key; SwiftUI sheets don't set modalWindow.
    if let key = NSApp.keyWindow, key.sheetParent === window { return }
    for w in NSApp.windows {
      if w.sheetParent === window { return }
    }
    let closeOnFocusLoss: Bool
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.geminiCloseOnFocusLoss) != nil {
      closeOnFocusLoss = UserDefaults.standard.bool(forKey: UserDefaultsKeys.geminiCloseOnFocusLoss)
    } else {
      closeOnFocusLoss = SettingsDefaults.geminiCloseOnFocusLoss
    }
    if closeOnFocusLoss {
      window?.close()
    }
  }

  func windowWillClose(_ notification: Notification) {
    cancellable?.cancel()
    cancellable = nil
    for o in sheetObservers {
      NotificationCenter.default.removeObserver(o)
    }
    sheetObservers = []
  }
}
