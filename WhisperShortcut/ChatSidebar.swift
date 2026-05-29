import SwiftUI

// MARK: - Sidebar for Gemini Chat session list

struct ChatSidebar: View {
  @ObservedObject var viewModel: ChatViewModel
  @Binding var sidebarVisible: Bool

  @State private var hoveredRowId: UUID? = nil
  @State private var renamingSessionId: UUID? = nil
  @State private var renameDraft: String = ""
  @State private var collapsedGroups: Set<DateGroup> = []
  @State private var collapsedMeetingGroups: Set<DateGroup> = []
  @State private var meetingsCollapsed = false
  @State private var archivedCollapsed = true
  @FocusState private var renameFieldFocused: Bool

  @State private var searchQuery: String = ""
  @State private var searchResults: [ChatViewModel.ChatSearchResult] = []
  @State private var hoveredResultId: UUID? = nil
  @State private var searchTask: Task<Void, Never>? = nil

  static let sidebarWidth: CGFloat = 220

  private var isSearching: Bool {
    !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private enum DateGroup: CaseIterable {
    case today, yesterday, previous7Days, previous30Days, older

    var label: String {
      switch self {
      case .today: return "Today"
      case .yesterday: return "Yesterday"
      case .previous7Days: return "Previous 7 Days"
      case .previous30Days: return "Previous 30 Days"
      case .older: return "Older"
      }
    }
  }

  private func dateGroup(for date: Date) -> DateGroup {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return .today }
    if cal.isDateInYesterday(date) { return .yesterday }
    let daysAgo = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
    if daysAgo < 7 { return .previous7Days }
    if daysAgo < 30 { return .previous30Days }
    return .older
  }

  private func groupedSessions(_ sessions: [ChatSession]) -> [(DateGroup, [ChatSession])] {
    grouped(sessions) { $0.lastUpdated }
  }

  /// Groups meetings by when the meeting actually took place (parsed from `meetingStem`),
  /// falling back to `lastUpdated` for sessions whose stem can't be parsed.
  private func groupedMeetings(_ sessions: [ChatSession]) -> [(DateGroup, [ChatSession])] {
    grouped(sessions) { session in
      session.meetingStem.flatMap(MeetingListService.date(fromStem:)) ?? session.lastUpdated
    }
  }

  private func grouped(_ sessions: [ChatSession], by date: (ChatSession) -> Date) -> [(DateGroup, [ChatSession])] {
    let sorted = sessions.sorted { date($0) > date($1) }
    var groups: [DateGroup: [ChatSession]] = [:]
    for session in sorted {
      let group = dateGroup(for: date(session))
      groups[group, default: []].append(session)
    }
    return DateGroup.allCases.compactMap { group in
      guard let items = groups[group], !items.isEmpty else { return nil }
      return (group, items)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      sidebarHeader
      Divider()
      searchField
      if isSearching {
        searchResultsView
      } else {
        sessionsScrollView
      }
    }
    .frame(width: Self.sidebarWidth)
    .background(ChatTheme.controlBackground)
    .onChange(of: searchQuery) { _ in scheduleSearch() }
  }

  private var sessionsScrollView: some View {
    ScrollView(.vertical, showsIndicators: true) {
        VStack(spacing: 0) {
          let all = viewModel.allSessionsList
          let active = all.filter { !$0.archived }
          let archived = all.filter { $0.archived }
          let pinned = active.filter { $0.pinned }.sorted { $0.lastUpdated > $1.lastUpdated }
          let rest = active.filter { !$0.pinned }
          let meetings = rest.filter { $0.isMeeting }.sorted { $0.lastUpdated > $1.lastUpdated }
          let unpinned = rest.filter { !$0.isMeeting }
          let grouped = groupedSessions(unpinned)

          if !pinned.isEmpty {
            sectionHeader("Pinned")
            ForEach(pinned, id: \.id) { session in
              sidebarRow(session: session)
            }
          }

          ForEach(Array(grouped.enumerated()), id: \.offset) { index, pair in
            collapsibleSectionHeader(pair.0, showDivider: !pinned.isEmpty || index > 0)
            if !collapsedGroups.contains(pair.0) {
              ForEach(pair.1, id: \.id) { session in
                sidebarRow(session: session)
              }
            }
          }

          if !meetings.isEmpty {
            collapsibleHeader(
              "Meetings",
              isCollapsed: meetingsCollapsed,
              showDivider: !pinned.isEmpty || !grouped.isEmpty
            ) {
              withAnimation(.easeInOut(duration: 0.15)) { meetingsCollapsed.toggle() }
            }
            if !meetingsCollapsed {
              ForEach(Array(groupedMeetings(meetings).enumerated()), id: \.offset) { _, pair in
                meetingDateSubHeader(pair.0)
                if !collapsedMeetingGroups.contains(pair.0) {
                  ForEach(pair.1, id: \.id) { session in
                    sidebarRow(session: session)
                  }
                }
              }
            }
          }

          if !archived.isEmpty {
            collapsibleHeader(
              "Archived",
              isCollapsed: archivedCollapsed,
              showDivider: !pinned.isEmpty || !grouped.isEmpty || !meetings.isEmpty
            ) {
              withAnimation(.easeInOut(duration: 0.15)) { archivedCollapsed.toggle() }
            }
            if !archivedCollapsed {
              ForEach(archived, id: \.id) { session in
                sidebarRow(session: session, isArchived: true)
              }
            }
          }
        }
        .padding(.leading, 10)
        .padding(.bottom, 8)
      }
  }

  // MARK: - Search

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundColor(ChatTheme.secondaryText.opacity(0.7))
      TextField("Search chats & meetings", text: $searchQuery)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundColor(ChatTheme.primaryText)
      if !searchQuery.isEmpty {
        Button(action: { searchQuery = "" }) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundColor(ChatTheme.secondaryText.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.windowBackground))
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private var searchResultsView: some View {
    ScrollView(.vertical, showsIndicators: true) {
      if searchResults.isEmpty {
        Text("No results")
          .font(.system(size: 12))
          .foregroundColor(ChatTheme.secondaryText)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.top, 24)
      } else {
        VStack(spacing: 0) {
          ForEach(searchResults) { result in
            searchResultRow(result)
          }
        }
        .padding(.bottom, 8)
      }
    }
  }

  private func searchResultRow(_ result: ChatViewModel.ChatSearchResult) -> some View {
    let isHovered = hoveredResultId == result.id
    return HStack(alignment: .top, spacing: 6) {
      Image(systemName: result.isMeeting ? "mic.circle.fill" : "bubble.left")
        .font(.system(size: 11))
        .foregroundColor(ChatTheme.secondaryText.opacity(0.6))
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(result.title)
          .font(.system(size: 13))
          .foregroundColor(ChatTheme.primaryText)
          .lineLimit(1)
          .truncationMode(.tail)
        if !result.snippet.isEmpty {
          Text(result.snippet)
            .font(.system(size: 11))
            .foregroundColor(ChatTheme.secondaryText)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 4)
      if result.sessionId == nil {
        Image(systemName: "arrow.up.forward.square")
          .font(.system(size: 10))
          .foregroundColor(ChatTheme.secondaryText.opacity(0.5))
          .padding(.top, 2)
          .help("Reveal transcript in Finder")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isHovered ? ChatTheme.windowBackground.opacity(0.5) : Color.clear)
    .contentShape(Rectangle())
    .onHover { over in hoveredResultId = over ? result.id : nil }
    .onTapGesture { openResult(result) }
  }

  private func scheduleSearch() {
    searchTask?.cancel()
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      searchResults = []
      return
    }
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 200_000_000)
      guard !Task.isCancelled else { return }
      searchResults = viewModel.search(query)
    }
  }

  private func openResult(_ result: ChatViewModel.ChatSearchResult) {
    if let sessionId = result.sessionId {
      viewModel.switchToSession(id: sessionId)
      searchQuery = ""
      searchResults = []
    } else if let url = result.meetingURL {
      viewModel.revealMeetingInFinder(url: url)
    }
  }

  // MARK: - Header

  private var sidebarHeader: some View {
    HStack {
      Button(action: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false } }) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(ChatTheme.primaryText)
      }
      .buttonStyle(.plain)
      .help("Hide sidebar")

      Spacer()

      Button(action: { viewModel.createNewSession() }) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(ChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("New chat")
    }
    .padding(.horizontal, 12)
    .frame(height: 52)
  }

  // MARK: - Section header

  private func sectionHeader(_ title: String, showDivider: Bool = false) -> some View {
    VStack(spacing: 0) {
      if showDivider {
        Divider()
          .padding(.horizontal, 10)
          .padding(.top, 12)
      }
      Text(title.uppercased())
        .font(.system(size: 9, weight: .bold, design: .default))
        .tracking(1.2)
        .foregroundColor(ChatTheme.secondaryText.opacity(0.8))
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.top, showDivider ? 12 : 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Lighter, indented, collapsible date sub-header grouping meetings under the "Meetings" header.
  /// Uses its own `collapsedMeetingGroups` state so it never shares collapse state with the chat date groups.
  private func meetingDateSubHeader(_ group: DateGroup) -> some View {
    let isCollapsed = collapsedMeetingGroups.contains(group)
    return HStack(spacing: 4) {
      Text(group.label.uppercased())
        .font(.system(size: 8.5, weight: .semibold, design: .default))
        .tracking(1.0)
        .foregroundColor(ChatTheme.secondaryText.opacity(0.6))
      Image(systemName: "chevron.right")
        .font(.system(size: 6, weight: .bold))
        .foregroundColor(ChatTheme.secondaryText.opacity(0.4))
        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
      Spacer()
    }
    .padding(.leading, 18)
    .padding(.trailing, 12)
    .padding(.top, 8)
    .padding(.bottom, 4)
    .contentShape(Rectangle())
    .onTapGesture { toggleCollapse(group, in: &collapsedMeetingGroups) }
  }

  private func collapsibleSectionHeader(_ group: DateGroup, showDivider: Bool = false) -> some View {
    collapsibleHeader(group.label, isCollapsed: collapsedGroups.contains(group), showDivider: showDivider) {
      toggleCollapse(group, in: &collapsedGroups)
    }
  }

  /// Animated toggle of a date group's collapsed state, shared by the chat date headers
  /// and the meeting date sub-headers (each passes its own backing set).
  private func toggleCollapse(_ group: DateGroup, in set: inout Set<DateGroup>) {
    withAnimation(.easeInOut(duration: 0.15)) {
      if set.contains(group) {
        set.remove(group)
      } else {
        set.insert(group)
      }
    }
  }

  private func collapsibleHeader(
    _ label: String, isCollapsed: Bool, showDivider: Bool, toggle: @escaping () -> Void
  ) -> some View {
    VStack(spacing: 0) {
      if showDivider {
        Divider()
          .padding(.horizontal, 10)
          .padding(.top, 12)
      }
      HStack(spacing: 4) {
        Text(label.uppercased())
          .font(.system(size: 9, weight: .bold, design: .default))
          .tracking(1.2)
          .foregroundColor(ChatTheme.secondaryText.opacity(0.8))
        Image(systemName: "chevron.right")
          .font(.system(size: 7, weight: .bold))
          .foregroundColor(ChatTheme.secondaryText.opacity(0.5))
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
        Spacer()
      }
      .padding(.leading, 10)
      .padding(.trailing, 12)
      .padding(.top, showDivider ? 12 : 14)
      .padding(.bottom, 6)
      .contentShape(Rectangle())
      .onTapGesture { toggle() }
    }
  }

  // MARK: - Row

  private func beginRename(_ session: ChatSession) {
    if let id = renamingSessionId, id != session.id { commitRename() }
    renameDraft = session.title ?? ""
    renamingSessionId = session.id
  }

  /// Saves the in-progress rename (if any) and exits edit mode. Idempotent.
  private func commitRename() {
    guard let id = renamingSessionId else { return }
    viewModel.renameSession(id: id, to: renameDraft)
    renamingSessionId = nil
  }

  private func sidebarRow(session: ChatSession, isArchived: Bool = false) -> some View {
    let isActive = session.id == viewModel.currentSessionId
    let isHovered = hoveredRowId == session.id
    let isPinned = session.pinned
    let title = ChatViewModel.displayTitle(for: session)

    let rowBg: Color = isActive
      ? ChatTheme.windowBackground
      : (isHovered ? ChatTheme.windowBackground.opacity(0.5) : Color.clear)

    let isRenaming = renamingSessionId == session.id
    let isMeetingLive = session.isMeeting && viewModel.isMeetingActive && viewModel.meetingSessionId == session.id

    return HStack(spacing: 0) {
      if isActive {
        Rectangle()
          .fill(Color.accentColor)
          .frame(width: 2)
      }

      if isRenaming {
        TextField("Title", text: $renameDraft, onCommit: { commitRename() })
        .font(.system(size: 13))
        .textFieldStyle(.plain)
        .padding(.leading, 10)
        .padding(.vertical, 6)
        .focused($renameFieldFocused)
        .onAppear { renameFieldFocused = true }
        .onChange(of: renameFieldFocused) { focused in
          // Clicking away (another chat, the composer, etc.) ends the rename and saves it.
          if !focused && renamingSessionId == session.id { commitRename() }
        }
        .onExitCommand { renamingSessionId = nil }
      } else {
        HStack(spacing: 6) {
          if session.isMeeting {
            Image(systemName: "mic.circle.fill")
              .font(.system(size: 11))
              .foregroundColor(isMeetingLive ? .red : ChatTheme.secondaryText.opacity(0.6))
          }
          Text(title)
            .font(.system(size: 13))
            .foregroundColor(isActive ? ChatTheme.primaryText : ChatTheme.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.leading, 10)
        .padding(.vertical, 8)
      }

      Spacer(minLength: 4)

      if isHovered && !isRenaming {
        Button(action: { viewModel.deleteSessionPermanently(id: session.id) }) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(ChatTheme.secondaryText.opacity(0.6))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(rowBg)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      beginRename(session)
    }
    .onTapGesture(count: 1) {
      commitRename()
      if isArchived {
        viewModel.restoreSession(id: session.id)
        viewModel.switchToSession(id: session.id)
      } else {
        viewModel.switchToSession(id: session.id)
      }
    }
    .onHover { over in hoveredRowId = over ? session.id : nil }
    .contextMenu {
      if isArchived {
        Button("Restore chat") {
          viewModel.restoreSession(id: session.id)
          viewModel.switchToSession(id: session.id)
        }
        Button("Copy chat") { viewModel.copyChatToClipboard(sessionId: session.id) }
        Divider()
        Button("Delete chat", role: .destructive) { viewModel.deleteSessionPermanently(id: session.id) }
      } else {
        Button("Rename\u{2026}") { beginRename(session) }
        if isPinned {
          Button("Unpin chat") { viewModel.unpinSession(id: session.id) }
        } else {
          Button("Pin chat") { viewModel.pinSession(id: session.id) }
        }
        Button("Copy chat") { viewModel.copyChatToClipboard(sessionId: session.id) }
        Divider()
        Button("Archive chat") { viewModel.archiveSession(id: session.id) }
        Button("Archive older chats") { viewModel.archiveOlderSessions(than: session.lastUpdated) }
        Divider()
        Button("Delete chat", role: .destructive) { viewModel.deleteSessionPermanently(id: session.id) }
      }
    }
  }
}
