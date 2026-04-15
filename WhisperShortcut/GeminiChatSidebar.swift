import SwiftUI

// MARK: - Sidebar for Gemini Chat session list

struct GeminiChatSidebar: View {
  @ObservedObject var viewModel: GeminiChatViewModel
  @Binding var sidebarVisible: Bool

  @State private var hoveredRowId: UUID? = nil
  @State private var deletingSessionId: UUID? = nil

  static let sidebarWidth: CGFloat = 220

  var body: some View {
    VStack(spacing: 0) {
      sidebarHeader
      Divider()
      ScrollView(.vertical, showsIndicators: true) {
        LazyVStack(spacing: 0) {
          let active = viewModel.recentSessions.sorted { $0.lastUpdated > $1.lastUpdated }
          let archived = viewModel.archivedSessionsList

          if !active.isEmpty {
            sectionHeader("Chats")
            ForEach(active, id: \.id) { session in
              sidebarRow(session: session, isArchived: false)
            }
          }

          if !archived.isEmpty {
            if !active.isEmpty {
              Divider()
                .padding(.top, 8)
            }
            sectionHeader("Archive")
            ForEach(archived, id: \.id) { session in
              sidebarRow(session: session, isArchived: true)
            }
          }
        }
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
      .font(.system(size: 10, weight: .semibold))
      .foregroundColor(GeminiChatTheme.secondaryText)
      .frame(width: Self.sidebarWidth, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.top, 12)
      .padding(.bottom, 4)
  }

  // MARK: - Row

  private func sidebarRow(session: ChatSession, isArchived: Bool) -> some View {
    let isActive = session.id == viewModel.currentSessionId
    let isHovered = hoveredRowId == session.id
    let rawTitle = session.title.flatMap { $0.isEmpty ? nil : $0 }
      ?? session.messages.first(where: { $0.role == .user })?.content.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "New chat"
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
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }
    .frame(width: Self.sidebarWidth, alignment: .leading)
    .background(rowBg)
    .contentShape(Rectangle())
    .overlay(alignment: .trailing) {
      if isHovered {
        HStack(spacing: 0) {
          LinearGradient(
            colors: [rowBg.opacity(0), rowBg],
            startPoint: .leading, endPoint: .trailing
          )
          .frame(width: 16)

          hoverActions(session: session, isArchived: isArchived)
            .padding(.trailing, 6)
            .background(rowBg)
        }
      }
    }
    .onTapGesture {
      if isArchived { viewModel.restoreSession(id: session.id) }
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

  // MARK: - Hover actions

  private func hoverActions(session: ChatSession, isArchived: Bool) -> some View {
    HStack(spacing: 2) {
      if isArchived {
        Button(action: { viewModel.restoreSession(id: session.id) }) {
          Image(systemName: "arrow.uturn.left")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(GeminiChatTheme.secondaryText)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Restore chat")
      } else {
        Button(action: { viewModel.archiveSession(id: session.id) }) {
          Image(systemName: "archivebox")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(GeminiChatTheme.secondaryText)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Archive chat")
      }
    }
  }
}
