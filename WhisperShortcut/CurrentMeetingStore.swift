//
//  CurrentMeetingStore.swift
//  WhisperShortcut
//
//  Persists and restores the last selected meeting for the Meeting window (for shortcut restore).
//

import Foundation
import Combine

private enum Constants {
  static let lastMeetingIdKey = "meeting_lastMeetingId"
}

/// Store for the Meeting window's current selection. Persists last opened meeting so the Open Meeting shortcut can restore it.
final class CurrentMeetingStore: ObservableObject {
  static let shared = CurrentMeetingStore()

  @Published private(set) var selectedMeeting: MeetingSelection = .live

  private let meetingListService = MeetingListService.shared

  private init() {
    restoreLastMeeting()
  }

  /// Restore selection from UserDefaults. Call after MeetingListService has refreshed.
  func restoreLastMeeting() {
    let id = UserDefaults.standard.string(forKey: Constants.lastMeetingIdKey) ?? "live"
    if id == "live" {
      selectedMeeting = .live
      return
    }
    meetingListService.refresh()
    if let info = meetingListService.meetings.first(where: { $0.meetingId == id }) {
      selectedMeeting = .pastMeeting(info)
    } else {
      selectedMeeting = .live
    }
  }

  /// Set the current meeting and persist for next open.
  func setSelectedMeeting(_ selection: MeetingSelection) {
    selectedMeeting = selection
    UserDefaults.standard.set(selection.meetingId, forKey: Constants.lastMeetingIdKey)
  }
}
