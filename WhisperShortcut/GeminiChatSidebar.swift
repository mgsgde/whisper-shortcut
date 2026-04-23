import SwiftUI

// MARK: - Sidebar for Gemini Chat session list

struct GeminiChatSidebar: View {
  @ObservedObject var viewModel: GeminiChatViewModel
  @Binding var sidebarVisible: Bool

  @State private var hoveredRowId: UUID? = nil
  @State private var deletingSessionId: UUID? = nil

  static let sidebarWidth: CGFloat = 220

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
    let sorted = sessions.sorted { $0.lastUpdated > $1.lastUpdated }
    var groups: [DateGroup: [ChatSession]] = [:]
    for session in sorted {
      let group = dateGroup(for: session.lastUpdated)
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
      ScrollView(.vertical, showsIndicators: true) {
        VStack(spacing: 0) {
          let active = viewModel.recentSessions
          let archived = viewModel.archivedSessionsList
          let grouped = groupedSessions(active)

          ForEach(Array(grouped.enumerated()), id: \.offset) { _, pair in
            sectionHeader(pair.0.label)
            ForEach(pair.1, id: \.id) { session in
              sidebarRow(session: session)
            }
          }

          if !archived.isEmpty {
            if !active.isEmpty {
              Divider()
                .padding(.top, 8)
            }
            sectionHeader("Archive")
            ForEach(archived, id: \.id) { session in
              sidebarRow(session: session)
            }
          }
        }
        // Inset session list from the sidebar edge; rows use maxWidth so hover fills this column.
        .padding(.leading, 10)
        .padding(.bottom, 8)
      }
    }
    .frame(width: Self.sidebarWidth)
    .background(GeminiChatTheme.controlBackground)
    .alert(
      "Delete chat?",
      isPresented: Binding(
        get: { deletingSessionId != nil },
        set: { if !$0 { deletingSessionId = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { deletingSessionId = nil }
      Button("Delete", role: .destructive) {
        if let id = deletingSessionId {
          viewModel.deleteSessionPermanently(id: id)
          deletingSessionId = nil
        }
      }
    } message: {
      Text("This chat will be permanently deleted. This action cannot be undone.")
    }
  }

  // MARK: - Header

  private var sidebarHeader: some View {
    HStack {
      Button(action: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false } }) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(GeminiChatTheme.primaryText)
      }
      .buttonStyle(.plain)
      .help("Hide sidebar")

      Spacer()

      Button(action: { viewModel.createNewSession() }) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("New chat")
    }
    .padding(.horizontal, 12)
    .frame(height: 52)
  }

  // MARK: - Section header

  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.system(size: 9, weight: .bold, design: .default))
      .tracking(1.2)
      .foregroundColor(GeminiChatTheme.secondaryText.opacity(0.8))
      .padding(.leading, 10)
      .padding(.trailing, 12)
      .padding(.top, 14)
      .padding(.bottom, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Row

  private func sidebarRow(session: ChatSession) -> some View {
    let isActive = session.id == viewModel.currentSessionId
    let isHovered = hoveredRowId == session.id
    let isArchived = session.archived
    let rawTitle: String = {
      if let t = session.title, !t.isEmpty {
        let stripped = unwrapUserMessageTypedByUser(t)
        return stripped.isEmpty ? t : stripped
      }
      if let firstContent = session.messages.first(where: { $0.role == .user })?.content {
        let cleaned = GeminiChatViewModel.contentForSessionTitle(firstContent)
        if !cleaned.isEmpty { return String(cleaned.prefix(60)) }
      }
      return "New chat"
    }()
    let title = rawTitle.replacingOccurrences(of: "\n", with: " ")

    let rowBg: Color = isActive
      ? GeminiChatTheme.windowBackground
      : (isHovered ? GeminiChatTheme.windowBackground.opacity(0.5) : Color.clear)

    return HStack(spacing: 0) {
      if isActive {
        Rectangle()
          .fill(Color.accentColor)
          .frame(width: 2)
      }

      Text(title)
        .font(.system(size: 13))
        .foregroundColor(isActive ? GeminiChatTheme.primaryText : GeminiChatTheme.secondaryText)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.leading, 10)
        .padding(.vertical, 8)

      Spacer(minLength: 4)

      if isHovered {
        hoverActionIcon(session: session, isArchived: isArchived)
          .padding(.trailing, 6)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(rowBg)
    .contentShape(Rectangle())
    .onTapGesture {
      DebugLogger.log("SIDEBAR: row tap id=\(session.id) archived=\(isArchived)")
      viewModel.switchToSession(id: session.id)
    }
    .onHover { over in hoveredRowId = over ? session.id : nil }
    .contextMenu {
      if isArchived {
        Button("Restore chat") { viewModel.restoreSession(id: session.id) }
      } else {
        Button("Archive chat") { viewModel.archiveSession(id: session.id) }
        Button("Archive older chats") { viewModel.archiveOlderSessions(than: session.lastUpdated) }
      }
      Divider()
      Button("Delete chat\u{2026}", role: .destructive) { deletingSessionId = session.id }
    }
  }

  // MARK: - Hover action icon

  @ViewBuilder
  private func hoverActionIcon(session: ChatSession, isArchived: Bool) -> some View {
    if isArchived {
      Image(systemName: "arrow.uturn.left")
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(GeminiChatTheme.secondaryText)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
          DebugLogger.log("SIDEBAR: restore icon tap id=\(session.id)")
          viewModel.restoreSession(id: session.id)
        })
        .help("Restore chat")
    } else {
      Image(systemName: "archivebox")
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(GeminiChatTheme.secondaryText)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
          DebugLogger.log("SIDEBAR: archive icon tap id=\(session.id)")
          viewModel.archiveSession(id: session.id)
        })
        .help("Archive chat")
    }
  }
}
