//
//  MeetingWindowManager.swift
//  WhisperShortcut
//
//  Manages the dedicated Meeting window. Show and restore last meeting.
//

import Cocoa

class MeetingWindowManager {
  static let shared = MeetingWindowManager()
  private var windowController: MeetingWindowController?

  private init() {}

  /// Opens the Meeting window and restores the last opened meeting. Does not start recording.
  func showAndRestoreLastMeeting() {
    if windowController == nil {
      windowController = MeetingWindowController()
    }
    CurrentMeetingStore.shared.restoreLastMeeting()
    windowController?.showWindow()
  }

  /// Shows the Meeting window (e.g. after starting a meeting from the menu). Restores last meeting state.
  func show() {
    showAndRestoreLastMeeting()
  }

  /// Toggle: hide if visible, show (and restore last meeting) if not.
  func toggle() {
    if isWindowOpen() {
      close()
    } else {
      show()
    }
  }

  func close() {
    windowController?.window?.close()
  }

  func isWindowOpen() -> Bool {
    guard let window = windowController?.window else { return false }
    return window.isVisible
  }
}
