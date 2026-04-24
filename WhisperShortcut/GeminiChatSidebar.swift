import SwiftUI

// MARK: - Sidebar for Gemini Chat session list

struct GeminiChatSidebar: View {
  @ObservedObject var viewModel: GeminiChatViewModel
  @Binding var sidebarVisible: Bool

  @State private var hoveredRowId: UUID? = nil
  @State private var renamingSessionId: UUID? = nil
  @State private var renameDraft: String = ""

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
          let all = viewModel.allSessionsList
          let pinned = all.filter { $0.pinned }.sorted { $0.lastUpdated > $1.lastUpdated }
          let unpinned = all.filter { !$0.pinned }
          let grouped = groupedSessions(unpinned)

          if !pinned.isEmpty {
            sectionHeader("Pinned")
            ForEach(pinned, id: \.id) { session in
              sidebarRow(session: session)
            }
          }

          ForEach(Array(grouped.enumerated()), id: \.offset) { index, pair in
            sectionHeader(pair.0.label, showDivider: !pinned.isEmpty || index > 0)
            ForEach(pair.1, id: \.id) { session in
              sidebarRow(session: session)
            }
          }
        }
        .padding(.leading, 10)
        .padding(.bottom, 8)
      }
    }
    .frame(width: Self.sidebarWidth)
    .background(GeminiChatTheme.controlBackground)
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
        .foregroundColor(GeminiChatTheme.secondaryText.opacity(0.8))
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.top, showDivider ? 12 : 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Row

  private func sidebarRow(session: ChatSession) -> some View {
    let isActive = session.id == viewModel.currentSessionId
    let isHovered = hoveredRowId == session.id
    let isPinned = session.pinned
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

    let isRenaming = renamingSessionId == session.id
    let isMeetingLive = session.isMeeting && viewModel.isMeetingActive && viewModel.meetingSessionId == session.id

    return HStack(spacing: 0) {
      if isActive {
        Rectangle()
          .fill(Color.accentColor)
          .frame(width: 2)
      }

      if isRenaming {
        TextField("Title", text: $renameDraft, onCommit: {
          viewModel.renameSession(id: session.id, to: renameDraft)
          renamingSessionId = nil
        })
        .font(.system(size: 13))
        .textFieldStyle(.plain)
        .padding(.leading, 10)
        .padding(.vertical, 6)
        .onExitCommand { renamingSessionId = nil }
      } else {
        HStack(spacing: 6) {
          if session.isMeeting {
            Image(systemName: "mic.circle.fill")
              .font(.system(size: 11))
              .foregroundColor(isMeetingLive ? .red : GeminiChatTheme.secondaryText.opacity(0.6))
          }
          Text(title)
            .font(.system(size: 13))
            .foregroundColor(isActive ? GeminiChatTheme.primaryText : GeminiChatTheme.secondaryText)
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
            .foregroundColor(GeminiChatTheme.secondaryText.opacity(0.6))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(rowBg)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      renameDraft = session.title ?? ""
      renamingSessionId = session.id
    }
    .onTapGesture(count: 1) {
      viewModel.switchToSession(id: session.id)
    }
    .onHover { over in hoveredRowId = over ? session.id : nil }
    .contextMenu {
      Button("Rename\u{2026}") {
        renameDraft = session.title ?? ""
        renamingSessionId = session.id
      }
      if isPinned {
        Button("Unpin chat") { viewModel.unpinSession(id: session.id) }
      } else {
        Button("Pin chat") { viewModel.pinSession(id: session.id) }
      }
      Divider()
      Button("Delete chat", role: .destructive) { viewModel.deleteSessionPermanently(id: session.id) }
      Button("Delete older chats", role: .destructive) { viewModel.deleteOlderSessions(than: session.lastUpdated) }
    }
  }
}
