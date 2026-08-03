import Foundation

/// A YouTube link found in a chat message, plus the optional start time from its `t`/`start`
/// parameter.
///
/// Gemini is the only provider that can actually *watch* a video: it accepts a YouTube URL as a
/// `file_data` part (video understanding). Its `url_context` tool explicitly excludes YouTube, so
/// without this part the model only sees the link as text and answers from web search — which is
/// exactly how it ends up confidently describing a video it never opened. Every other provider
/// converts only `text` and `inline_data` parts, so attachment is gated on Gemini in `ChatView`.
///
/// Live-verified against `gemini-3.6-flash` on 2026-08-03:
/// - a 19-minute video attaches fine unclipped (~100k video+audio tokens);
/// - a 2-hour video is rejected with a bare `400 INVALID_ARGUMENT` (no usable message), so long
///   videos MUST carry a `video_metadata` window — hence `clippedPart` and the retry in
///   `GeminiAPIClient`;
/// - `end_offset` past the end of the video is clamped, but a `start_offset` past the end drops
///   the video silently (2 prompt tokens), so the pre-roll never goes negative;
/// - `media_resolution` (part-level or in `generationConfig`) is rejected by this model — there is
///   no cheap-resolution lever, only a shorter window.
struct YouTubeVideoLink: Equatable {
  /// The 11-character video id.
  let videoID: String
  /// Start time in seconds from `t=` / `start=`, when the user linked a specific moment.
  let startSeconds: Int?

  // MARK: - Policy

  /// How much video to send when clipping. ~90 tokens/second of video+audio, so 10 minutes is
  /// ~55k tokens — a few cents per turn on Flash, and the part is re-sent with every follow-up.
  static let clipWindowSeconds = 600
  /// Rewind a little before the linked moment: people paste the timestamp of the answer, not of
  /// the question that set it up.
  static let preRollSeconds = 60
  /// Videos attached per request. Gemini 2.5+ accepts up to 10; the limit here is cost, not the API.
  static let maxVideosPerRequest = 2

  // MARK: - Derived

  /// Canonical watch URL. Query junk (`si=`, playlist ids, the timestamp itself) is dropped so the
  /// same video posted twice yields one identical part — and so `t=` can't fight `video_metadata`.
  var canonicalURL: String { "https://www.youtube.com/watch?v=\(videoID)" }

  /// Window sent to Gemini when this link is clipped: `preRoll` before the linked moment, clamped
  /// at zero, `clipWindowSeconds` long.
  var clipRange: (start: Int, end: Int) {
    let start = max(0, (startSeconds ?? 0) - Self.preRollSeconds)
    return (start, start + Self.clipWindowSeconds)
  }

  /// Whether this link should be clipped up front. A linked moment means the user is asking about
  /// that moment, so sending the whole (often multi-hour) video is both wasteful and rejected.
  var shouldClipUpFront: Bool { startSeconds != nil }

  // MARK: - Gemini parts

  /// The `file_data` part, clipped when the user linked a specific moment.
  var geminiVideoPart: [String: Any] {
    var part: [String: Any] = ["file_data": ["file_uri": canonicalURL]]
    if shouldClipUpFront {
      let range = clipRange
      part["video_metadata"] = [
        "start_offset": "\(range.start)s",
        "end_offset": "\(range.end)s",
      ]
    }
    return part
  }

  /// Opening of `geminiContextNote`, so the note that travels with a video part can be found and
  /// dropped again when the part itself is removed (see `removeVideoParts`).
  static let contextNotePrefix = "[Attached YouTube video:"

  /// Model-facing note that travels with the video part. Without it the model reports clip-relative
  /// timestamps as if they were absolute, and has no way to tell the user that the rest of a long
  /// video was not watched.
  var geminiContextNote: String {
    guard shouldClipUpFront else {
      return "\(Self.contextNotePrefix) \(canonicalURL) — the full video is included above.]"
    }
    let range = clipRange
    return "\(Self.contextNotePrefix) \(canonicalURL) — only the segment "
      + "\(Self.formatTimestamp(range.start))–\(Self.formatTimestamp(range.end)) is included above, "
      + "because the user linked \(Self.formatTimestamp(startSeconds ?? 0)). Timestamps you cite are "
      + "offsets into that segment; convert them to positions in the full video. If the answer needs "
      + "material outside this window, say so instead of guessing.]"
  }

  /// `H:MM:SS` / `M:SS`, matching how YouTube itself shows positions.
  static func formatTimestamp(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }

  // MARK: - Detection

  private static let patterns: [String] = [
    // youtube.com/watch?v=ID, /shorts/ID, /live/ID, /embed/ID, /v/ID  (+ trailing query)
    #"(?:https?://)?(?:www\.|m\.)?(?:youtube\.com|youtube-nocookie\.com)/(?:watch\?(?:[^\s]*?&)?v=|shorts/|live/|embed/|v/)([A-Za-z0-9_-]{11})([^\s]*)"#,
    // youtu.be/ID
    #"(?:https?://)?youtu\.be/([A-Za-z0-9_-]{11})([^\s]*)"#,
  ]

  private static let regexes: [NSRegularExpression] = patterns.compactMap {
    try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
  }

  /// Every YouTube link in `text`, in order of appearance, deduplicated by video id (the first
  /// occurrence wins, so a link that carries a timestamp isn't replaced by a bare repeat).
  static func detect(in text: String) -> [YouTubeVideoLink] {
    guard !text.isEmpty else { return [] }
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    var found: [(location: Int, link: YouTubeVideoLink)] = []
    for regex in regexes {
      for match in regex.matches(in: text, options: [], range: full) {
        guard match.numberOfRanges >= 2 else { continue }
        let videoID = ns.substring(with: match.range(at: 1))
        let trailing = match.numberOfRanges >= 3 && match.range(at: 2).location != NSNotFound
          ? ns.substring(with: match.range(at: 2))
          : ""
        found.append(
          (match.range.location, YouTubeVideoLink(videoID: videoID, startSeconds: startSeconds(inQuery: trailing))))
      }
    }
    // Deduplicate only after sorting: the two URL shapes are matched by separate passes, so
    // filtering per pass would let a bare `youtube.com/watch?v=ID` repeat later in the message
    // win over the `youtu.be/ID?t=90` the user actually linked first.
    var seen = Set<String>()
    return found
      .sorted { $0.location < $1.location }
      .filter { seen.insert($0.link.videoID).inserted }
      .map(\.link)
  }

  /// Reads `t` / `start` out of a URL query fragment. Accepts YouTube's own formats: `90`, `90s`,
  /// `1h50m10s`, `2m`, `1h`.
  static func startSeconds(inQuery query: String) -> Int? {
    let stripped = query.hasPrefix("?") || query.hasPrefix("&") ? String(query.dropFirst()) : query
    for pair in stripped.split(whereSeparator: { $0 == "&" || $0 == "?" || $0 == "#" }) {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, parts[0] == "t" || parts[0] == "start" else { continue }
      if let seconds = parseDuration(String(parts[1])) { return seconds }
    }
    return nil
  }

  /// `"6610"` / `"6610s"` / `"1h50m10s"` → seconds. Returns nil for anything else.
  static func parseDuration(_ raw: String) -> Int? {
    let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !value.isEmpty else { return nil }
    if let plain = Int(value) { return plain >= 0 ? plain : nil }
    var total = 0
    var digits = ""
    var sawUnit = false
    for ch in value {
      if ch.isNumber {
        digits.append(ch)
        continue
      }
      guard let amount = Int(digits) else { return nil }
      switch ch {
      case "h": total += amount * 3600
      case "m": total += amount * 60
      case "s": total += amount
      default: return nil
      }
      sawUnit = true
      digits = ""
    }
    // Trailing digits without a unit ("1h30") are not a format YouTube emits — reject rather than
    // guess a unit and land the window in the wrong place.
    return sawUnit && digits.isEmpty ? total : nil
  }

  // MARK: - Fallback clipping

  /// Clips every unclipped YouTube `file_data` part in a request body to the opening window, for
  /// the one retry after a bare `400` (see the class doc). Returns nil when there is nothing to
  /// clip — i.e. when the 400 came from something else and a retry would be pointless.
  static func clipUnclippedVideoParts(in contents: [[String: Any]]) -> [[String: Any]]? {
    var didClip = false
    let clipped = contents.map { content -> [String: Any] in
      guard var parts = content["parts"] as? [[String: Any]] else { return content }
      var clippedHere = false
      for (index, part) in parts.enumerated() {
        guard part["video_metadata"] == nil,
              let fileData = part["file_data"] as? [String: Any],
              let uri = fileData["file_uri"] as? String,
              isYouTubeURL(uri)
        else { continue }
        var updated = part
        updated["video_metadata"] = ["start_offset": "0s", "end_offset": "\(clipWindowSeconds)s"]
        parts[index] = updated
        clippedHere = true
      }
      guard clippedHere else { return content }
      didClip = true
      var content = content
      content["parts"] = parts
      return content
    }
    return didClip ? clipped : nil
  }

  /// Removes every YouTube `file_data` part — and the context note that travels with it — from a
  /// request body, for the one retry after a `403 PERMISSION_DENIED`.
  ///
  /// Gemini can only open *public* videos; a private, unlisted, or otherwise restricted link is
  /// refused outright (live-verified 2026-08-03). Since the video is attached automatically from a
  /// link in the user's text, that 403 otherwise kills the whole turn — including a question that
  /// had nothing to do with the video. Returns nil when the request carries no video, i.e. when the
  /// 403 came from something else (a revoked or restricted key) and a retry would be pointless.
  static func removeVideoParts(in contents: [[String: Any]]) -> [[String: Any]]? {
    var didRemove = false
    let stripped = contents.map { content -> [String: Any] in
      guard let parts = content["parts"] as? [[String: Any]] else { return content }
      var kept: [[String: Any]] = []
      var removedHere = false
      // The note is a separate text part right after its video part; dropping the video without it
      // would leave the model reading "the full video is included above" with no video above.
      var justDroppedVideo = false
      for part in parts {
        if let fileData = part["file_data"] as? [String: Any],
           let uri = fileData["file_uri"] as? String,
           isYouTubeURL(uri) {
          removedHere = true
          justDroppedVideo = true
          continue
        }
        if justDroppedVideo, (part["text"] as? String)?.hasPrefix(contextNotePrefix) == true {
          justDroppedVideo = false
          continue
        }
        justDroppedVideo = false
        kept.append(part)
      }
      guard removedHere else { return content }
      didRemove = true
      var content = content
      // A content with no parts at all is rejected, so never let stripping empty one out.
      content["parts"] = kept.isEmpty ? [["text": permissionDeniedNote]] : kept
      return content
    }
    return didRemove ? stripped : nil
  }

  /// Note appended after the video is stripped, so the model tells the user it could not watch the
  /// video instead of answering as if it had.
  static var permissionDeniedNote: String {
    "[The attached YouTube video could not be opened: this model can only watch public videos, and "
      + "the linked one is private, unlisted, or otherwise restricted. Answer the rest of the message "
      + "normally, but say plainly that you could not watch the video — do not describe its contents.]"
  }

  static func isYouTubeURL(_ uri: String) -> Bool {
    let lowered = uri.lowercased()
    return lowered.contains("youtube.com/") || lowered.contains("youtu.be/")
      || lowered.contains("youtube-nocookie.com/")
  }

  /// Note appended after the fallback clip, so the model (and through it the user) knows the video
  /// was too long to watch in full.
  static var fallbackClipNote: String {
    "[The attached YouTube video was too long for this model to process in full. Only the first "
      + "\(formatTimestamp(clipWindowSeconds)) were included. Say so in your answer, and ask the user to "
      + "link a timestamp (e.g. `&t=1h20m`) for any later part of the video.]"
  }
}
