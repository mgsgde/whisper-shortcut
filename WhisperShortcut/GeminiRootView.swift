import SwiftUI

enum GeminiViewMode: String, CaseIterable {
  case chat = "Chat"
  case meeting = "Meeting"
}

/// Unified selection for the meeting dropdown: live session or a specific past meeting.
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

/// Root view for the Open Gemini window. Contains a Chat | Meeting segmented control
/// and renders either the plain Gemini chat or the meeting split view with a dropdown.
struct GeminiRootView: View {
  @State private var mode: GeminiViewMode = .chat
  @State private var selectedMeeting: MeetingSelection = .live

  @ObservedObject private var liveStore = LiveMeetingTranscriptStore.shared
  @ObservedObject private var meetingListService = MeetingListService.shared

  var body: some View {
    VStack(spacing: 0) {
      modeToolbar
      Divider()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onReceive(NotificationCenter.default.publisher(for: .geminiSwitchToMeeting)) { _ in
      mode = .meeting
      selectedMeeting = .live
    }
    .onAppear {
      meetingListService.refresh()
    }
    .onChange(of: mode) { _, newMode in
      if newMode == .meeting {
        meetingListService.refresh()
        autoSelectMeetingIfNeeded()
        NotificationCenter.default.post(name: .geminiSwitchToMeeting, object: nil)
      } else {
        NotificationCenter.default.post(name: .geminiSwitchToChat, object: nil)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch mode {
    case .chat:
      GeminiChatView()
    case .meeting:
      meetingContent
    }
  }

  // MARK: - Mode toolbar (segmented control + optional meeting picker)

  private var modeToolbar: some View {
    HStack(spacing: 12) {
      Picker("", selection: $mode) {
        ForEach(GeminiViewMode.allCases, id: \.self) { m in
          Text(m.rawValue).tag(m)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 160)

      if mode == .meeting {
        Text("Meeting:")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(GeminiChatTheme.secondaryText)
        meetingPicker
      }

      Spacer()

      Button {
        NotificationCenter.default.post(name: .geminiToggleLiveMeeting, object: nil)
      } label: {
        HStack(spacing: 4) {
          if liveStore.isSessionActive {
            Image(systemName: "stop.circle.fill")
              .font(.system(size: 12))
              .foregroundColor(.red)
            Text("Stop Meeting")
              .font(.system(size: 12, weight: .medium))
          } else {
            Image(systemName: "record.circle")
              .font(.system(size: 12))
            Text("Start Meeting")
              .font(.system(size: 12, weight: .medium))
          }
        }
        .foregroundColor(GeminiChatTheme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(liveStore.isSessionActive ? "Stop live meeting transcription" : "Start live meeting transcription")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(GeminiChatTheme.controlBackground.opacity(0.5))
  }

  // MARK: - Meeting picker dropdown

  private var meetingPicker: some View {
    let hasLive = liveStore.isSessionActive || !liveStore.chunks.isEmpty

    return Menu {
      if hasLive {
        Button(action: { selectedMeeting = .live }) {
          HStack {
            if liveStore.isSessionActive {
              Image(systemName: "record.circle")
            }
            Text(liveStore.isSessionActive ? "Live" : "Live (ended)")
          }
        }
        if !meetingListService.meetings.isEmpty {
          Divider()
        }
      }
      ForEach(meetingListService.meetings) { meeting in
        Button(meeting.displayLabel) {
          selectedMeeting = .pastMeeting(meeting)
        }
      }
    } label: {
      HStack(spacing: 4) {
        if case .live = selectedMeeting, liveStore.isSessionActive {
          Image(systemName: "record.circle")
            .foregroundColor(.red)
            .font(.system(size: 9))
        }
        Text(selectedMeeting.displayLabel)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(GeminiChatTheme.primaryText)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .medium))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(GeminiChatTheme.controlBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity), lineWidth: 1)
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .onChange(of: selectedMeeting) { _, _ in
      meetingListService.refresh()
    }
  }

  // MARK: - Meeting content (split view or empty state)

  @ViewBuilder
  private var meetingContent: some View {
    let hasLive = liveStore.isSessionActive || !liveStore.chunks.isEmpty
    let hasPastMeetings = !meetingListService.meetings.isEmpty

    if !hasLive && !hasPastMeetings {
      meetingEmptyState
    } else {
      meetingSplitForSelection
    }
  }

  /// If no live meeting and current selection is live, auto-select newest past meeting.
  private func autoSelectMeetingIfNeeded() {
    let hasLive = liveStore.isSessionActive || !liveStore.chunks.isEmpty
    if case .live = selectedMeeting, !hasLive, let newest = meetingListService.meetings.first {
      selectedMeeting = .pastMeeting(newest)
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
      Text("Start a meeting from the menu bar to see it here.")
        .font(.subheadline)
        .foregroundColor(GeminiChatTheme.secondaryText.opacity(0.7))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GeminiChatTheme.windowBackground)
  }

  @ViewBuilder
  private var meetingSplitForSelection: some View {
    switch selectedMeeting {
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
        summary: "",
        isSessionActive: false,
        store: GeminiChatSessionStore(scope: info.meetingId),
        meetingContextProvider: { [chunks] in
          meetingListService.contextString(for: chunks)
        }
      )
      .id(info.meetingId)
    }
  }
}
