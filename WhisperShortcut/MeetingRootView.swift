//
//  MeetingRootView.swift
//  WhisperShortcut
//
//  Root view for the dedicated Meeting window. One meeting at a time; no tabs or dropdown.
//

import SwiftUI

struct MeetingRootView: View {
  @ObservedObject private var currentMeetingStore = CurrentMeetingStore.shared
  @ObservedObject private var liveStore = LiveMeetingTranscriptStore.shared
  @ObservedObject private var meetingListService = MeetingListService.shared

  @State private var showMeetingLibrary = false
  @State private var showRecordingActiveAlert = false
  @State private var pendingOpenLibraryAfterStop = false
  @State private var showEndMeetingNameSheet = false
  @State private var endMeetingNameInput = ""
  @State private var showRenameSheet = false
  @State private var renameSheetIsLive = false
  @State private var renameInput = ""
  @State private var meetingToRename: MeetingFileInfo?
  @State private var pastMeetingSummary: String = ""
  @State private var pastMeetingSummaryLoading: Bool = false

  /// Title shown in toolbar: preferred/file name for live, displayLabel for past.
  private var currentMeetingTitle: String {
    switch currentMeetingStore.selectedMeeting {
    case .live:
      return liveStore.preferredMeetingName ?? liveStore.currentMeetingFilenameStem ?? "Meeting"
    case .pastMeeting(let info):
      return info.displayLabel
    }
  }

  /// True when we show the split view (has live or past meetings), so we show the title in toolbar.
  private var hasMeetingContent: Bool {
    liveStore.isSessionActive || !liveStore.chunks.isEmpty || !meetingListService.meetings.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      meetingToolbar
      Divider()
        .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $showMeetingLibrary) {
      MeetingLibrarySheet(
        onSelect: { selection in
          currentMeetingStore.setSelectedMeeting(selection)
          showMeetingLibrary = false
        },
        onDismiss: { showMeetingLibrary = false }
      )
    }
    .sheet(isPresented: $showEndMeetingNameSheet) {
      endMeetingNameSheet
    }
    .sheet(isPresented: $showRenameSheet) {
      renameMeetingSheet
    }
    .onAppear {
      meetingListService.refresh()
      currentMeetingStore.restoreLastMeeting()
    }
    .onChange(of: liveStore.isSessionActive) { _, isActive in
      if !isActive && pendingOpenLibraryAfterStop {
        pendingOpenLibraryAfterStop = false
        showMeetingLibrary = true
      }
    }
    .onChange(of: showMeetingLibrary) { _, isShowing in
      NotificationCenter.default.post(
        name: isShowing ? .meetingWindowSheetDidPresent : .meetingWindowSheetDidDismiss,
        object: nil
      )
    }
    .onChange(of: showEndMeetingNameSheet) { _, isShowing in
      NotificationCenter.default.post(
        name: isShowing ? .meetingWindowSheetDidPresent : .meetingWindowSheetDidDismiss,
        object: nil
      )
    }
    .onChange(of: showRenameSheet) { _, isShowing in
      NotificationCenter.default.post(
        name: isShowing ? .meetingWindowSheetDidPresent : .meetingWindowSheetDidDismiss,
        object: nil
      )
    }
    .onReceive(NotificationCenter.default.publisher(for: .showMeetingLibraryInMeetingWindow)) { _ in
      if liveStore.isSessionActive {
        showRecordingActiveAlert = true
      } else {
        showMeetingLibrary = true
      }
    }
    .alert("Recording is active", isPresented: $showRecordingActiveAlert) {
      Button("Stop & Open") {
        pendingOpenLibraryAfterStop = true
        NotificationCenter.default.post(name: .geminiToggleLiveMeeting, object: nil)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Stop the current recording to open another meeting.")
    }
  }

  private var endMeetingNameSheet: some View {
    VStack(spacing: 16) {
      Text("Name this meeting")
        .font(.headline)
      TextField("Meeting name", text: $endMeetingNameInput)
        .textFieldStyle(.roundedBorder)
        .onAppear {
          if endMeetingNameInput.isEmpty {
            endMeetingNameInput = liveStore.preferredMeetingName ?? liveStore.currentMeetingFilenameStem ?? "Meeting"
          }
        }
      HStack(spacing: 12) {
        Button("Cancel") {
          showEndMeetingNameSheet = false
        }
        .keyboardShortcut(.cancelAction)
        Spacer()
        Button("End Meeting") {
          let name = endMeetingNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
          let finalName = name.isEmpty ? (liveStore.currentMeetingFilenameStem ?? "Meeting") : name
          showEndMeetingNameSheet = false
          NotificationCenter.default.post(
            name: .geminiEndMeetingWithName,
            object: nil,
            userInfo: ["meetingName": finalName]
          )
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(minWidth: 320)
  }

  private var renameMeetingSheet: some View {
    VStack(spacing: 16) {
      Text("Rename meeting")
        .font(.headline)
      TextField("Meeting name", text: $renameInput)
        .textFieldStyle(.roundedBorder)
      HStack(spacing: 12) {
        Button("Cancel") {
          showRenameSheet = false
        }
        .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Save") {
          let name = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
          if renameSheetIsLive {
            liveStore.preferredMeetingName = name.isEmpty ? nil : name
          } else if let meeting = meetingToRename, !name.isEmpty,
                    let updated = meetingListService.renameMeeting(meeting, newDisplayName: name) {
            currentMeetingStore.setSelectedMeeting(.pastMeeting(updated))
            meetingListService.refresh()
          }
          showRenameSheet = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(renameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !renameSheetIsLive)
      }
    }
    .padding(24)
    .frame(minWidth: 320)
  }

  private var meetingToolbar: some View {
    HStack(spacing: 12) {
      if hasMeetingContent {
        Button {
          renameInput = currentMeetingTitle
          switch currentMeetingStore.selectedMeeting {
          case .live:
            renameSheetIsLive = true
            meetingToRename = nil
          case .pastMeeting(let info):
            renameSheetIsLive = false
            meetingToRename = info
          }
          showRenameSheet = true
        } label: {
          Text(currentMeetingTitle)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .help("Click to rename meeting")
        .frame(maxWidth: 280, alignment: .leading)
      }

      Spacer()

      Button("New Meeting") {
        currentMeetingStore.setSelectedMeeting(.live)
        LiveMeetingTranscriptStore.shared.clearForNewMeeting()
        NotificationCenter.default.post(name: .geminiToggleLiveMeeting, object: nil)
      }
      .buttonStyle(.bordered)
      .disabled(liveStore.isSessionActive)
      .help("Start a new meeting (recording starts automatically). End the current meeting first.")

      Button("End Meeting") {
        endMeetingNameInput = liveStore.preferredMeetingName ?? liveStore.currentMeetingFilenameStem ?? "Meeting"
        showEndMeetingNameSheet = true
      }
      .buttonStyle(.bordered)
      .disabled(!liveStore.isSessionActive)
      .help("Stop recording and end the current meeting")

      Button("Open Meeting") {
        showMeetingLibrary = true
      }
      .buttonStyle(.bordered)
      .disabled(liveStore.isSessionActive)
      .help("Open a meeting from the library. End the current meeting first.")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(GeminiChatTheme.controlBackground.opacity(0.5))
  }

  @ViewBuilder
  private var content: some View {
    let hasLive = liveStore.isSessionActive || !liveStore.chunks.isEmpty
    let hasPastMeetings = !meetingListService.meetings.isEmpty

    if !hasLive && !hasPastMeetings {
      meetingEmptyState
    } else {
      meetingSplitForCurrent
    }
  }

  private var meetingEmptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "waveform.slash")
        .font(.system(size: 36))
        .foregroundColor(GeminiChatTheme.secondaryText.opacity(0.5))
      Text("No meetings yet")
        .font(.headline)
        .foregroundColor(GeminiChatTheme.secondaryText)
      Text("Use \"New Meeting\" to start (recording begins automatically).")
        .font(.subheadline)
        .foregroundColor(GeminiChatTheme.secondaryText.opacity(0.7))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GeminiChatTheme.windowBackground)
  }

  @ViewBuilder
  private var meetingSplitForCurrent: some View {
    switch currentMeetingStore.selectedMeeting {
    case .live:
      MeetingChatSplitView(
        chunks: liveStore.chunks,
        summary: liveStore.summary,
        isSessionActive: liveStore.isSessionActive,
        store: GeminiChatSessionStore(scope: "live"),
        meetingContextProvider: {
          LiveMeetingTranscriptStore.shared.meetingContextForChat(lastMinutes: 5)
        }
      )
      .id("live")
    case .pastMeeting(let info):
      let chunks = meetingListService.chunks(for: info)
      MeetingChatSplitView(
        chunks: chunks,
        summary: pastMeetingSummary,
        summaryLoading: pastMeetingSummaryLoading,
        isSessionActive: false,
        store: GeminiChatSessionStore(scope: info.meetingId),
        meetingContextProvider: { [chunks] in
          meetingListService.contextString(for: chunks)
        }
      )
      .id(info.meetingId)
      .task(id: info.meetingId) {
        pastMeetingSummaryLoading = true
        pastMeetingSummary = await meetingListService.summary(for: info)
        pastMeetingSummaryLoading = false
      }
    }
  }
}
