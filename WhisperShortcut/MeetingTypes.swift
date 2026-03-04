//
//  MeetingTypes.swift
//  WhisperShortcut
//
//  Shared types for the Meeting window: selection between live session or a past meeting.
//

import Foundation

/// Unified selection for the meeting window: live session or a specific past meeting.
enum MeetingSelection: Hashable {
  case live
  case pastMeeting(MeetingFileInfo)

  var displayLabel: String {
    switch self {
    case .live: return "Live"
    case .pastMeeting(let info): return info.displayLabel
    }
  }

  var meetingId: String {
    switch self {
    case .live: return "live"
    case .pastMeeting(let info): return info.meetingId
    }
  }
}
