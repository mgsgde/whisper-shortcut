import SwiftUI

/// Split view for the Meeting Chat window: left = Gemini chat with meeting context, right = scrollable transcript + optional summary.
/// Accepts all data as parameters so the same view works for both live meetings and loaded past meetings.
struct MeetingChatSplitView: View {
  let chunks: [LiveMeetingChunk]
  let summary: String
  /// When true and !isSessionActive and summary isEmpty, show "Generating summary..." instead of "No summary".
  var summaryLoading: Bool = false
  let isSessionActive: Bool
  let store: GeminiChatSessionStore
  let meetingContextProvider: (() -> String?)?

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
    Group {
      if isSessionActive {
        VStack(alignment: .leading, spacing: 0) {
          summaryHeaderLive
          Divider()
            .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
          summaryContentLive
            .frame(maxHeight: .infinity)
          Divider()
            .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
          transcriptHeader
          Divider()
            .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
          transcriptList
        }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          endedMeetingSummaryHeader
          Divider()
            .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
          endedMeetingSummaryBody
        }
      }
    }
    .frame(width: width, alignment: .leading)
    .background(GeminiChatTheme.controlBackground)
  }

  /// Header for the right column when meeting is ended or past: title + Copy transcript.
  private var endedMeetingSummaryHeader: some View {
    HStack {
      Image(systemName: "text.alignleft")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(GeminiChatTheme.secondaryText)
      Text("Meeting summary")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(GeminiChatTheme.primaryText)
      Spacer()
      if !chunks.isEmpty {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(fullTranscriptText, forType: .string)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "doc.on.doc")
              .font(.system(size: 11))
            Text("Copy transcript")
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

  /// Scrollable Markdown summary body when meeting is ended or past.
  private var endedMeetingSummaryBody: some View {
    Group {
      if summary.isEmpty {
        Text(summaryLoading ? "Generating summary..." : summaryPlaceholder)
          .font(.system(size: 13))
          .foregroundColor(GeminiChatTheme.secondaryText)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          markdownSummaryView
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var markdownSummaryView: some View {
    Group {
      if let attributed = try? AttributedString(markdown: summary, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)) {
        Text(attributed)
          .font(.system(size: 14))
          .lineSpacing(6)
          .foregroundColor(GeminiChatTheme.primaryText)
          .textSelection(.enabled)
      } else {
        Text(summary)
          .font(.system(size: 14))
          .lineSpacing(6)
          .foregroundColor(GeminiChatTheme.primaryText)
          .textSelection(.enabled)
      }
    }
  }

  /// Header for Summary in the live meeting right column (top section).
  private var summaryHeaderLive: some View {
    HStack {
      HStack(spacing: 6) {
        Image(systemName: "text.alignleft")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.accentColor)
        Text("Summary")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(GeminiChatTheme.primaryText)
      }
      Spacer()
      if !summary.isEmpty {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(summary, forType: .string)
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
        .help("Copy summary to clipboard")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  /// Scrollable summary content for live meeting (used below summaryHeaderLive).
  private var summaryContentLive: some View {
    Group {
      if !summary.isEmpty {
        ScrollView {
          markdownSummaryView
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else if isSessionActive {
        summaryPlaceholderLive
      } else {
        Text(summaryPlaceholder)
          .font(.system(size: 13))
          .foregroundColor(GeminiChatTheme.secondaryText)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  /// Shown in live meeting while summary is still empty (matches liveTranscriptPlaceholder style).
  private var summaryPlaceholderLive: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
        .tint(GeminiChatTheme.secondaryText)
      Text(summaryPlaceholder)
        .font(.system(size: 13))
        .foregroundColor(GeminiChatTheme.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var summaryPlaceholder: String {
    if isSessionActive {
      return "Summary will update here as the meeting continues (every few minutes)."
    }
    return "No summary for this meeting."
  }

  /// Full transcript as a single string so the user can select and copy everything at once.
  /// Single newline between chunks keeps segments visually distinct without excessive spacing.
  private var fullTranscriptText: String {
    chunks.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n")
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
              .lineSpacing(4)
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
