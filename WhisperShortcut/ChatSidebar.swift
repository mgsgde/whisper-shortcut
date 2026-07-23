import SwiftUI

// MARK: - Sidebar for Gemini Chat session list
//
// Layout: header → single vertical scroll view containing two stacked sections.
//   • CHATS: search field, date groups (Today and Yesterday expanded by default,
//     the rest collapsed), Archived (collapsed).
//   • MEETINGS: search field, date groups (Today and Yesterday expanded by
//     default, the rest collapsed), Archived (collapsed).

struct ChatSidebar: View {
  @ObservedObject var viewModel: ChatViewModel
  @Binding var sidebarVisible: Bool

  @State private var hoveredRowId: UUID? = nil
  @State private var renamingSessionId: UUID? = nil
  @State private var renameDraft: String = ""
  @FocusState private var renameFieldFocused: Bool
  @State private var hoveredResultId: UUID? = nil

  // Global search state — one query, results across both chats and meetings.
  @State private var searchQuery: String = ""
  @State private var searchResults: [ChatViewModel.ChatSearchResult] = []
  @State private var searchTask: Task<Void, Never>? = nil

  // Chats section state
  @State private var chatsSectionCollapsed = false
  @State private var chatCollapsedGroups: Set<DateGroup>
  @State private var chatArchivedCollapsed = true

  // Meetings section state — like chats, Today and Yesterday start expanded; the
  // rest are collapsed so the list stays short.
  @State private var meetingsSectionCollapsed = false
  @State private var meetingCollapsedGroups: Set<DateGroup>
  @State private var meetingArchivedCollapsed = true

  static let sidebarWidth: CGFloat = 220

  init(viewModel: ChatViewModel, sidebarVisible: Binding<Bool>) {
    self._viewModel = ObservedObject(wrappedValue: viewModel)
    self._sidebarVisible = sidebarVisible
    self._chatCollapsedGroups = State(initialValue: Self.defaultCollapsedGroups())
    self._meetingCollapsedGroups = State(initialValue: Self.defaultCollapsedGroups())
  }

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

  private static func dateGroup(for date: Date) -> DateGroup {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return .today }
    if cal.isDateInYesterday(date) { return .yesterday }
    let daysAgo = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
    if daysAgo < 7 { return .previous7Days }
    if daysAgo < 30 { return .previous30Days }
    return .older
  }

  /// Collapse every date group except Today and Yesterday.
  private static func defaultCollapsedGroups() -> Set<DateGroup> {
    Set([.previous7Days, .previous30Days, .older])
  }

  /// Date a meeting buckets by: when the meeting took place (parsed from
  /// `meetingStem`), falling back to `lastUpdated`.
  private static func meetingSortDate(_ session: ChatSession) -> Date {
    session.meetingStem.flatMap(MeetingListService.date(fromStem:)) ?? session.lastUpdated
  }

  /// Date a session sorts and groups by. Meetings bucket by meeting date;
  /// chats always use `lastUpdated`.
  private func sortDate(_ session: ChatSession) -> Date {
    session.isMeeting ? Self.meetingSortDate(session) : session.lastUpdated
  }

  private func grouped(_ sessions: [ChatSession], by date: (ChatSession) -> Date)
    -> [(DateGroup, [ChatSession])]
  {
    let sorted = sessions.sorted { date($0) > date($1) }
    var groups: [DateGroup: [ChatSession]] = [:]
    for session in sorted {
      let group = Self.dateGroup(for: date(session))
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
      searchField(
        placeholder: "Search chats & meetings",
        text: $searchQuery,
        isSearching: isSearching,
        clearAction: { searchQuery = "" },
        topPadding: 8)
      ScrollView(.vertical, showsIndicators: true) {
        VStack(spacing: 0) {
          if isSearching {
            searchResultsView(results: searchResults)
          } else {
            chatsSection
            meetingsSection
          }
        }
        .padding(.bottom, 8)
      }
    }
    .frame(width: Self.sidebarWidth)
    .background(ChatTheme.sidebarBackground)
    .onChange(of: searchQuery) { _ in scheduleSearch() }
  }

  // MARK: - Chats section

  @ViewBuilder
  private var chatsSection: some View {
    let chats = viewModel.allSessionsList.filter { !$0.isMeeting }
    let active = chats.filter { !$0.archived }
    let archived = chats.filter { $0.archived }
    let grouped = grouped(active, by: sortDate)

    sectionHeaderRow(
      title: "Chats",
      isCollapsed: chatsSectionCollapsed,
      toggleCollapse: { chatsSectionCollapsed.toggle() },
      actionIcon: "square.and.pencil",
      actionHelp: "New chat",
      actionTint: ChatTheme.secondaryText,
      topPadding: 16
    ) {
      viewModel.createNewSession()
    }
    if !chatsSectionCollapsed {
      ForEach(Array(grouped.enumerated()), id: \.offset) { index, pair in
        collapsibleHeader(
          pair.0.label,
          isCollapsed: chatCollapsedGroups.contains(pair.0),
          showDivider: index > 0
        ) {
          toggleCollapse(pair.0, in: &chatCollapsedGroups)
        }
        if !chatCollapsedGroups.contains(pair.0) {
          ForEach(pair.1, id: \.id) { session in
            sidebarRow(session: session)
          }
        }
      }
      if !archived.isEmpty {
        collapsibleHeader(
          "Archived",
          isCollapsed: chatArchivedCollapsed,
          showDivider: !grouped.isEmpty
        ) {
          withAnimation(.easeInOut(duration: 0.15)) { chatArchivedCollapsed.toggle() }
        }
        if !chatArchivedCollapsed {
          ForEach(archived, id: \.id) { session in
            sidebarRow(session: session, isArchived: true)
          }
        }
      }
    }
  }

  // MARK: - Meetings section

  @ViewBuilder
  private var meetingsSection: some View {
    let meetings = viewModel.allSessionsList.filter { $0.isMeeting }
    let active = meetings.filter { !$0.archived }
    let archived = meetings.filter { $0.archived }
    let grouped = grouped(active, by: sortDate)
    let meetingLive = viewModel.isMeetingActive

    sectionGap
    sectionHeaderRow(
      title: "Meetings",
      isCollapsed: meetingsSectionCollapsed,
      toggleCollapse: { meetingsSectionCollapsed.toggle() },
      actionIcon: "square.and.pencil",
      actionHelp: meetingLive
        ? "Stop the current meeting recording"
        : "Start a new live meeting recording",
      actionTint: ChatTheme.secondaryText,
      topPadding: 8
    ) {
      viewModel.handleMeetingButtonTap()
    }
    if !meetingsSectionCollapsed {
      if active.isEmpty && archived.isEmpty {
        Text("No meetings yet")
          .font(.system(size: 12))
          .foregroundColor(ChatTheme.secondaryText)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.top, 12)
          .padding(.bottom, 8)
      } else {
        ForEach(Array(grouped.enumerated()), id: \.offset) { index, pair in
          collapsibleHeader(
            pair.0.label,
            isCollapsed: meetingCollapsedGroups.contains(pair.0),
            showDivider: index > 0
          ) {
            toggleCollapse(pair.0, in: &meetingCollapsedGroups)
          }
          if !meetingCollapsedGroups.contains(pair.0) {
            ForEach(pair.1, id: \.id) { session in
              sidebarRow(session: session)
            }
          }
        }
        if !archived.isEmpty {
          collapsibleHeader(
            "Archived",
            isCollapsed: meetingArchivedCollapsed,
            showDivider: !grouped.isEmpty
          ) {
            withAnimation(.easeInOut(duration: 0.15)) { meetingArchivedCollapsed.toggle() }
          }
          if !meetingArchivedCollapsed {
            ForEach(archived, id: \.id) { session in
              sidebarRow(session: session, isArchived: true)
            }
          }
        }
      }
    }
  }

  // MARK: - Section header row (Chats / Meetings title + action button)

  private func sectionHeaderRow(
    title: String,
    isCollapsed: Bool,
    toggleCollapse: @escaping () -> Void,
    actionIcon: String,
    actionHelp: String,
    actionTint: Color,
    topPadding: CGFloat,
    perform: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(ChatTheme.secondaryText.opacity(0.7))
        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
        .frame(width: 12, alignment: .center)
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(ChatTheme.primaryText)
      Spacer()
      Button(action: perform) {
        Image(systemName: actionIcon)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(actionTint)
      }
      .buttonStyle(.plain)
      .help(actionHelp)
      .accessibilityLabel(actionHelp)
    }
    .padding(.leading, 12)
    .padding(.trailing, 12)
    .padding(.top, topPadding)
    .padding(.bottom, 8)
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.15)) { toggleCollapse() }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
  }

  // Hairline divider used to mark the boundary between Chats and Meetings.
  // Symmetric vertical padding keeps the line equidistant from both headers.
  /// Vertical breathing room between the Chats and Meetings sections (no visible line).
  private var sectionGap: some View {
    Color.clear.frame(height: 10)
  }

  // MARK: - Search field

  private func searchField(
    placeholder: String,
    text: Binding<String>,
    isSearching: Bool,
    clearAction: @escaping () -> Void,
    topPadding: CGFloat
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundColor(ChatTheme.secondaryText.opacity(0.7))
      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundColor(ChatTheme.primaryText)
      if isSearching {
        Button(action: clearAction) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundColor(ChatTheme.secondaryText.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help("Clear search")
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.windowBackground))
    .padding(.horizontal, 10)
    .padding(.top, topPadding)
    .padding(.bottom, 6)
  }

  // MARK: - Search results

  @ViewBuilder
  private func searchResultsView(results: [ChatViewModel.ChatSearchResult]) -> some View {
    if results.isEmpty {
      Text("No results")
        .font(.system(size: 12))
        .foregroundColor(ChatTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 12)
        .padding(.bottom, 8)
    } else {
      ForEach(results) { result in
        searchResultRow(result)
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
    .background(isHovered ? Color.primary.opacity(0.07) : Color.clear)
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
      Button(action: {
        withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false }
      }) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(ChatTheme.primaryText)
      }
      .buttonStyle(.plain)
      .help("Hide sidebar")
      .accessibilityLabel("Hide sidebar")

      Spacer()
    }
    .padding(.horizontal, 12)
    .frame(height: 52)
  }

  // MARK: - Collapsible date / archived headers

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
      HStack(spacing: 5) {
        Image(systemName: "chevron.right")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(ChatTheme.secondaryText.opacity(0.55))
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          .frame(width: 10, alignment: .center)
        Text(label.uppercased())
          .font(.system(size: 9, weight: .bold, design: .default))
          .tracking(1.2)
          .foregroundColor(ChatTheme.secondaryText.opacity(0.65))
        Spacer()
      }
      .padding(.leading, 14)
      .padding(.trailing, 12)
      .padding(.top, showDivider ? 10 : 12)
      .padding(.bottom, 4)
      .contentShape(Rectangle())
      .onTapGesture { toggle() }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
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
    let title = ChatViewModel.displayTitle(for: session)

    let isRenaming = renamingSessionId == session.id

    // System Settings-style selection: solid accent background + white text.
    let textColor: Color =
      isActive ? .white : ChatTheme.primaryText

    let rowBg: Color =
      isActive
      ? Color.accentColor
      : (isHovered ? Color.primary.opacity(0.07) : Color.clear)

    // Hover button: active → archive, archived → delete permanently. Each step
    // is one click away from removal — never an irreversible action by accident.
    let kind = session.isMeeting ? "meeting" : "chat"
    let hoverAction: (icon: String, help: String, perform: () -> Void) = {
      if isArchived {
        return (
          "xmark", "Delete permanently", { viewModel.deleteSessionPermanently(id: session.id) }
        )
      } else {
        return ("archivebox", "Archive \(kind)", { viewModel.archiveSession(id: session.id) })
      }
    }()

    let isRecording = viewModel.isMeetingActive && viewModel.meetingSessionId == session.id

    return HStack(spacing: 8) {
      if isRecording {
        Circle()
          .fill(Color.red)
          .frame(width: 6, height: 6)
          .help("Recording")
      }
      if isRenaming {
        TextField("Title", text: $renameDraft, onCommit: { commitRename() })
          .font(.system(size: 13))
          .textFieldStyle(.plain)
          .focused($renameFieldFocused)
          .onAppear { renameFieldFocused = true }
          .onChange(of: renameFieldFocused) { focused in
            // Clicking away (another chat, the composer, etc.) ends and saves the rename.
            if !focused && renamingSessionId == session.id { commitRename() }
          }
          .onExitCommand { renamingSessionId = nil }
      } else {
        Text(title)
          .font(.system(size: 13))
          .foregroundColor(textColor)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: 4)

      if isHovered && !isRenaming {
        Button(action: hoverAction.perform) {
          Image(systemName: hoverAction.icon)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(
              isActive
                ? Color.white.opacity(0.85)
                : ChatTheme.secondaryText.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(hoverAction.help)
        .accessibilityLabel(hoverAction.help)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 6).fill(rowBg))
    .padding(.horizontal, 6)
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
      let kind = session.isMeeting ? "meeting" : "chat"
      let archiveOlderCutoff = sortDate(session)
      if isArchived {
        Button("Restore \(kind)") {
          viewModel.restoreSession(id: session.id)
          viewModel.switchToSession(id: session.id)
        }
        Button("Copy \(kind)") { viewModel.copyChatToClipboard(sessionId: session.id) }
        Divider()
        Button("Delete \(kind)", role: .destructive) {
          viewModel.deleteSessionPermanently(id: session.id)
        }
      } else {
        Button("Rename\u{2026}") { beginRename(session) }
        Button("Copy \(kind)") { viewModel.copyChatToClipboard(sessionId: session.id) }
        Divider()
        Button("Archive \(kind)") { viewModel.archiveSession(id: session.id) }
          .keyboardShortcut(.delete, modifiers: .command)
        if session.isMeeting {
          Button("Archive older meetings") {
            viewModel.archiveOlderMeetings(than: archiveOlderCutoff)
          }
          Button("Archive other meetings") {
            viewModel.archiveOtherMeetings(except: session.id)
          }
        } else {
          Button("Archive older chats") {
            viewModel.archiveOlderSessions(than: archiveOlderCutoff)
          }
          Button("Archive other chats") {
            viewModel.archiveOtherSessions(except: session.id)
          }
        }
        Divider()
        Button("Delete \(kind)", role: .destructive) {
          viewModel.deleteSessionPermanently(id: session.id)
        }
      }
    }
  }
}
