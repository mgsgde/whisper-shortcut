import SwiftUI

/// Split view for the Meeting Chat window: left = Gemini chat with meeting context, right = live transcript + optional summary.
struct MeetingChatSplitView: View {
  @ObservedObject private var transcriptStore = LiveMeetingTranscriptStore.shared
  @State private var summaryExpanded: Bool = true

  /// Fraction of width for the chat (left) side. Right side gets 1 - chatFraction.
  private let chatFraction: CGFloat = 0.55

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        chatColumn(width: geometry.size.width * chatFraction)
        Divider()
          .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
        transcriptColumn(width: geometry.size.width * (1 - chatFraction))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GeminiChatTheme.windowBackground)
  }

  private func chatColumn(width: CGFloat) -> some View {
    GeminiChatView(
      meetingContextProvider: {
        LiveMeetingTranscriptStore.shared.meetingContextForChat(lastMinutes: 5)
      },
      createNewSessionOnAppear: true
    )
    .frame(width: width, alignment: .leading)
  }

  private func transcriptColumn(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      transcriptHeader
      Divider()
        .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
      if !transcriptStore.summary.isEmpty {
        summarySection
      }
      transcriptList
    }
    .frame(width: width, alignment: .leading)
    .background(GeminiChatTheme.controlBackground)
  }

  private var summarySection: some View {
    DisclosureGroup(isExpanded: $summaryExpanded) {
      ScrollView {
        Text(transcriptStore.summary)
          .font(.system(size: 12))
          .foregroundColor(GeminiChatTheme.primaryText)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 160)
      .padding(.vertical, 4)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "text.alignleft")
          .font(.system(size: 11))
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("Summary")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(GeminiChatTheme.primaryText)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private var transcriptHeader: some View {
    HStack {
      Image(systemName: "waveform")
        .foregroundColor(.accentColor)
        .font(.system(size: 12, weight: .medium))
      Text("Live transcript")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(GeminiChatTheme.primaryText)
      if !transcriptStore.isSessionActive {
        Text("(ended)")
          .font(.system(size: 11))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var transcriptList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(transcriptStore.chunks) { chunk in
            transcriptRow(chunk: chunk)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .onChange(of: transcriptStore.chunks.count) { _, _ in
        if let last = transcriptStore.chunks.last {
          withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func transcriptRow(chunk: LiveMeetingChunk) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(chunk.timestampString)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(GeminiChatTheme.secondaryText)
        .frame(width: 44, alignment: .leading)
      Text(chunk.text)
        .font(.system(size: 12))
        .foregroundColor(GeminiChatTheme.primaryText)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 2)
  }
}
