import SwiftUI

/// Split view for the Meeting Chat window: left = Gemini chat with meeting context, right = scrollable transcript + optional summary.
/// Accepts all data as parameters so the same view works for both live meetings and loaded past meetings.
struct MeetingChatSplitView: View {
  let chunks: [LiveMeetingChunk]
  let summary: String
  let isSessionActive: Bool
  let store: GeminiChatSessionStore
  let meetingContextProvider: (() -> String?)?

  @State private var summaryExpanded: Bool = true

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
      meetingContextProvider: meetingContextProvider,
      createNewSessionOnAppear: false,
      store: store,
      singleChatOnly: true
    )
    .frame(width: width, alignment: .leading)
  }

  private func transcriptColumn(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      transcriptHeader
      Divider()
        .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
      summarySection
      Divider()
        .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
      transcriptList
    }
    .frame(width: width, alignment: .leading)
    .background(GeminiChatTheme.controlBackground)
  }

  private var summarySection: some View {
    DisclosureGroup(isExpanded: $summaryExpanded) {
      Group {
        if !summary.isEmpty {
          ScrollView {
            Text(summary)
              .font(.system(size: 14))
              .lineSpacing(6)
              .foregroundColor(GeminiChatTheme.primaryText)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 220)
        } else {
          Text(summaryPlaceholder)
            .font(.system(size: 13))
            .foregroundColor(GeminiChatTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.vertical, 8)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "text.alignleft")
          .font(.system(size: 12))
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("Summary")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(GeminiChatTheme.primaryText)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(GeminiChatTheme.windowBackground.opacity(0.6))
  }

  private var summaryPlaceholder: String {
    if isSessionActive {
      return "Summary will update here as the meeting continues (every few minutes)."
    }
    return "No summary for this meeting."
  }

  /// Full transcript as a single string so the user can select and copy everything at once.
  /// Double newlines add visual spacing between chunks while keeping one selectable block.
  private var fullTranscriptText: String {
    chunks.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n\n")
  }

  private var transcriptHeader: some View {
    HStack {
      Image(systemName: "waveform")
        .foregroundColor(.accentColor)
        .font(.system(size: 12, weight: .medium))
      Text(isSessionActive ? "Live transcript" : "Transcript")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(GeminiChatTheme.primaryText)
      if isSessionActive {
        // No extra label while live
      } else if !chunks.isEmpty {
        Text("(\(chunks.count) chunks)")
          .font(.system(size: 11))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      Spacer()
      if !chunks.isEmpty {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(fullTranscriptText, forType: .string)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "doc.on.doc")
              .font(.system(size: 11))
            Text("Copy")
              .font(.system(size: 11, weight: .medium))
          }
          .foregroundColor(GeminiChatTheme.secondaryText)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy full transcript to clipboard")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var transcriptList: some View {
    Group {
      if isSessionActive && chunks.isEmpty {
        liveTranscriptPlaceholder
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            Text(fullTranscriptText)
              .font(.system(size: 12))
              .lineSpacing(6)
              .foregroundColor(GeminiChatTheme.primaryText)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .id("transcriptBottom")
          }
          .onChange(of: chunks.count) { _, _ in
            if isSessionActive {
              withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("transcriptBottom", anchor: .bottom)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Shown while recording has started but no transcript chunks have arrived yet (chunks every ~15 s).
  private var liveTranscriptPlaceholder: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
        .tint(GeminiChatTheme.secondaryText)
      Text("Transcription appears here about every 15 seconds.")
        .font(.system(size: 13))
        .foregroundColor(GeminiChatTheme.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
