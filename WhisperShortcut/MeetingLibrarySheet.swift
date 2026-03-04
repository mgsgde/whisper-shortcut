//
//  MeetingLibrarySheet.swift
//  WhisperShortcut
//
//  Sheet listing past meetings; select one to open, or Delete from the list. Rename is in the main Meeting view (click title).
//

import SwiftUI

struct MeetingLibrarySheet: View {
  @ObservedObject private var meetingListService = MeetingListService.shared
  let onSelect: (MeetingSelection) -> Void
  let onDismiss: () -> Void

  @State private var meetingToDelete: MeetingFileInfo?
  @State private var showDeleteConfirm = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Meeting Library")
          .font(.headline)
        Spacer()
        Button("Done") {
          onDismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding()

      if meetingListService.meetings.isEmpty {
        Text("No past meetings")
          .foregroundColor(GeminiChatTheme.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(meetingListService.meetings) { meeting in
          HStack {
            Button {
              onSelect(.pastMeeting(meeting))
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayLabel)
                  .font(.body)
                Text(meeting.meetingId)
                  .font(.caption)
                  .foregroundColor(GeminiChatTheme.secondaryText)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button("Delete") {
              meetingToDelete = meeting
              showDeleteConfirm = true
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
          }
        }
      }
    }
    .frame(minWidth: 400, minHeight: 300)
    .onAppear {
      meetingListService.refresh()
    }
    .alert("Delete meeting?", isPresented: $showDeleteConfirm) {
      Button("Cancel", role: .cancel) {
        meetingToDelete = nil
      }
      Button("Delete", role: .destructive) {
        if let meeting = meetingToDelete {
          _ = meetingListService.deleteMeeting(meeting)
          if CurrentMeetingStore.shared.selectedMeeting.meetingId == meeting.meetingId {
            CurrentMeetingStore.shared.setSelectedMeeting(.live)
          }
          meetingToDelete = nil
        }
      }
    } message: {
      if let m = meetingToDelete {
        Text("\u{201C}\(m.displayLabel)\u{201D} will be permanently deleted.")
      }
    }
  }
}
