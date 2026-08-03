import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers YouTube link detection and the clip window derived from it.
///
/// Both failure directions are silent and expensive: miss the link and Gemini answers about a video
/// it never watched (the bug this feature exists to fix), or mis-parse the timestamp and we ship a
/// ten-minute window from the wrong part of a two-hour podcast — the model then answers confidently
/// about the wrong passage.
@Suite("YouTube video links")
struct YouTubeVideoLinkTests {

  @Test("Every YouTube URL shape the user can paste is detected")
  func detectsURLShapes() {
    let cases: [(String, String)] = [
      ("https://www.youtube.com/watch?v=-yfvcb0MHtc", "-yfvcb0MHtc"),
      ("https://youtube.com/watch?v=aircAruvnKk&list=PLZHQ", "aircAruvnKk"),
      ("http://m.youtube.com/watch?app=desktop&v=aircAruvnKk", "aircAruvnKk"),
      ("youtu.be/aircAruvnKk?si=abc", "aircAruvnKk"),
      ("https://www.youtube.com/shorts/aircAruvnKk", "aircAruvnKk"),
      ("https://www.youtube.com/live/aircAruvnKk", "aircAruvnKk"),
      ("https://www.youtube-nocookie.com/embed/aircAruvnKk", "aircAruvnKk"),
    ]
    for (text, expectedID) in cases {
      let links = YouTubeVideoLink.detect(in: "Schau dir das an: \(text) — was meint er?")
      #expect(links.map(\.videoID) == [expectedID], "failed for \(text)")
    }
  }

  @Test("Text without a YouTube link produces nothing")
  func ignoresOtherText() {
    #expect(YouTubeVideoLink.detect(in: "").isEmpty)
    #expect(YouTubeVideoLink.detect(in: "See https://vimeo.com/123456789 and https://example.com").isEmpty)
    // Not a video id: too short to be one, so there is nothing to attach.
    #expect(YouTubeVideoLink.detect(in: "https://www.youtube.com/watch?v=short").isEmpty)
  }

  @Test("Timestamps parse in every format YouTube emits")
  func parsesTimestamps() {
    #expect(YouTubeVideoLink.parseDuration("6610") == 6610)
    #expect(YouTubeVideoLink.parseDuration("6610s") == 6610)
    #expect(YouTubeVideoLink.parseDuration("1h50m10s") == 6610)
    #expect(YouTubeVideoLink.parseDuration("2m") == 120)
    #expect(YouTubeVideoLink.parseDuration("1h") == 3600)
    // A unit-less trailing number would be a guess — reject rather than clip the wrong passage.
    #expect(YouTubeVideoLink.parseDuration("1h30") == nil)
    #expect(YouTubeVideoLink.parseDuration("später") == nil)
  }

  @Test("The linked moment becomes the clip window; without one the video stays unclipped")
  func buildsClipWindow() {
    let linked = YouTubeVideoLink.detect(in: "https://www.youtube.com/watch?v=-yfvcb0MHtc&t=6610s")
    #expect(linked.count == 1)
    let link = try! #require(linked.first)
    #expect(link.startSeconds == 6610)
    #expect(link.shouldClipUpFront)
    #expect(link.clipRange.start == 6610 - YouTubeVideoLink.preRollSeconds)
    #expect(link.clipRange.end == link.clipRange.start + YouTubeVideoLink.clipWindowSeconds)

    let part = link.geminiVideoPart
    let fileData = part["file_data"] as? [String: Any]
    // The timestamp must not survive in the URI — `t=` and `video_metadata` would then disagree.
    #expect(fileData?["file_uri"] as? String == "https://www.youtube.com/watch?v=-yfvcb0MHtc")
    let metadata = part["video_metadata"] as? [String: Any]
    #expect(metadata?["start_offset"] as? String == "6550s")
    #expect(metadata?["end_offset"] as? String == "7150s")

    let bare = try! #require(YouTubeVideoLink.detect(in: "https://youtu.be/aircAruvnKk").first)
    #expect(bare.startSeconds == nil)
    #expect(!bare.shouldClipUpFront)
    #expect(bare.geminiVideoPart["video_metadata"] == nil)
  }

  @Test("A repeated video is attached once, in order of first appearance")
  func deduplicatesByVideoID() {
    let links = YouTubeVideoLink.detect(
      in: "https://youtu.be/aircAruvnKk?t=90 vs https://www.youtube.com/watch?v=-yfvcb0MHtc "
        + "— nochmal https://www.youtube.com/watch?v=aircAruvnKk")
    #expect(links.map(\.videoID) == ["aircAruvnKk", "-yfvcb0MHtc"])
    // First occurrence wins, so the timestamp the user actually linked is kept.
    #expect(links.first?.startSeconds == 90)
  }

  @Test("The 400 fallback clips only unclipped YouTube parts")
  func fallbackClipping() {
    let contents: [[String: Any]] = [
      ["role": "user", "parts": [
        ["text": "Was sagt er?"],
        ["file_data": ["file_uri": "https://www.youtube.com/watch?v=aircAruvnKk"]],
      ]]
    ]
    let clipped = try! #require(YouTubeVideoLink.clipUnclippedVideoParts(in: contents))
    let parts = clipped.first?["parts"] as? [[String: Any]]
    let metadata = parts?[1]["video_metadata"] as? [String: Any]
    #expect(metadata?["start_offset"] as? String == "0s")
    #expect(metadata?["end_offset"] as? String == "\(YouTubeVideoLink.clipWindowSeconds)s")

    // Already clipped, or no video at all: nothing to retry, so the 400 must surface as-is.
    #expect(YouTubeVideoLink.clipUnclippedVideoParts(in: clipped) == nil)
    #expect(YouTubeVideoLink.clipUnclippedVideoParts(
      in: [["role": "user", "parts": [["text": "hi"]]]]) == nil)
  }

  @Test("The 403 fallback drops the video part together with its context note")
  func permissionDeniedStripping() {
    let link = YouTubeVideoLink(videoID: "aircAruvnKk", startSeconds: nil)
    let contents: [[String: Any]] = [
      ["role": "user", "parts": [
        ["inline_data": ["mime_type": "image/png", "data": "AAAA"]],
        link.geminiVideoPart,
        ["text": link.geminiContextNote],
        ["text": "Was sagt er in https://youtu.be/aircAruvnKk ?"],
      ]]
    ]
    let stripped = try! #require(YouTubeVideoLink.removeVideoParts(in: contents))
    let parts = try! #require(stripped.first?["parts"] as? [[String: Any]])
    // The image and the user's own question survive; the video and its now-false caption do not.
    #expect(parts.count == 2)
    #expect(parts[0]["inline_data"] != nil)
    #expect(parts[1]["text"] as? String == "Was sagt er in https://youtu.be/aircAruvnKk ?")

    // Stripped already, or never had a video: the 403 is about something else and must surface.
    #expect(YouTubeVideoLink.removeVideoParts(in: stripped) == nil)
    #expect(YouTubeVideoLink.removeVideoParts(
      in: [["role": "user", "parts": [["text": "hi"]]]]) == nil)
  }

  @Test("Stripping never leaves a content without parts")
  func permissionDeniedKeepsPartsNonEmpty() {
    let link = YouTubeVideoLink(videoID: "aircAruvnKk", startSeconds: 90)
    let stripped = try! #require(YouTubeVideoLink.removeVideoParts(
      in: [["role": "user", "parts": [link.geminiVideoPart, ["text": link.geminiContextNote]]]]))
    let parts = try! #require(stripped.first?["parts"] as? [[String: Any]])
    #expect(parts.count == 1)
    #expect(parts[0]["text"] as? String == YouTubeVideoLink.permissionDeniedNote)
  }

  @Test("Timestamps are formatted the way YouTube shows them")
  func formatsTimestamps() {
    #expect(YouTubeVideoLink.formatTimestamp(0) == "0:00")
    #expect(YouTubeVideoLink.formatTimestamp(95) == "1:35")
    #expect(YouTubeVideoLink.formatTimestamp(6610) == "1:50:10")
  }
}
