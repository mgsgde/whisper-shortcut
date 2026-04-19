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
  @AppStorage(UserDefaultsKeys.meetingTranscriptSectionExpanded) private var isTranscriptSectionExpanded: Bool = true

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
          if isTranscriptSectionExpanded {
            Divider()
              .background(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity))
            transcriptList
          }
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
    MarkdownBlockView(text: summary)
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
  /// Single newline between chunks keeps spacing compact.
  private var fullTranscriptText: String {
    chunks.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n")
  }

  private static let speakerColors: [Color] = [
    .orange, .purple, .pink, .cyan, .yellow, .mint
  ]

  /// Transcript with timestamps in accent (blue) and speaker labels color-coded.
  private var attributedTranscriptText: AttributedString {
    var result = AttributedString()
    for (index, chunk) in chunks.enumerated() {
      var ts = AttributedString(chunk.timestampString)
      ts.foregroundColor = Color.accentColor
      result.append(ts)

      let text = " " + chunk.text
      result.append(coloredSpeakerText(text))

      if index < chunks.count - 1 {
        result.append(AttributedString("\n"))
      }
    }
    return result
  }

  /// Colors speaker labels (Speaker A:, Speaker B:, etc.) in transcript text.
  private func coloredSpeakerText(_ text: String) -> AttributedString {
    var result = AttributedString()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (i, line) in lines.enumerated() {
      let lineStr = String(line)
      if let match = lineStr.range(of: #"Speaker [A-Z]:"#, options: .regularExpression) {
        let label = String(lineStr[match])
        let speakerLetter = label.dropFirst("Speaker ".count).dropLast(1)
        let colorIndex = max(0, Int(speakerLetter.first?.asciiValue ?? 65) - 65) % Self.speakerColors.count
        let before = String(lineStr[lineStr.startIndex..<match.lowerBound])
        if !before.isEmpty {
          var attr = AttributedString(before)
          attr.foregroundColor = GeminiChatTheme.primaryText
          result.append(attr)
        }
        var labelAttr = AttributedString(label)
        labelAttr.foregroundColor = Self.speakerColors[colorIndex]
        labelAttr.font = .system(size: 12, weight: .semibold)
        result.append(labelAttr)
        let after = String(lineStr[match.upperBound...])
        var rest = AttributedString(after)
        rest.foregroundColor = GeminiChatTheme.primaryText
        result.append(rest)
      } else {
        var attr = AttributedString(lineStr)
        attr.foregroundColor = GeminiChatTheme.primaryText
        result.append(attr)
      }
      if i < lines.count - 1 {
        result.append(AttributedString("\n"))
      }
    }
    return result
  }

  private var transcriptHeader: some View {
    HStack {
      if isSessionActive {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            isTranscriptSectionExpanded.toggle()
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: isTranscriptSectionExpanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundColor(GeminiChatTheme.secondaryText)
            Image(systemName: "waveform")
              .foregroundColor(.accentColor)
              .font(.system(size: 12, weight: .medium))
            Text("Live transcript")
              .font(.system(size: 13, weight: .semibold))
              .foregroundColor(GeminiChatTheme.primaryText)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isTranscriptSectionExpanded ? "Collapse live transcript" : "Expand live transcript")
      } else {
        Image(systemName: "waveform")
          .foregroundColor(.accentColor)
          .font(.system(size: 12, weight: .medium))
        Text("Transcript")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(GeminiChatTheme.primaryText)
        if !chunks.isEmpty {
          Text("(\(chunks.count) chunks)")
            .font(.system(size: 11))
            .foregroundColor(GeminiChatTheme.secondaryText)
        }
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
            Text(attributedTranscriptText)
              .font(.system(size: 12))
              .lineSpacing(4)
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
      Text("Transcription appears here periodically as the meeting progresses.")
        .font(.system(size: 13))
        .foregroundColor(GeminiChatTheme.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
