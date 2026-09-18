import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The byte-level splitter both Gemini streams (chat and TTS) read `streamGenerateContent` with:
/// it must emit each top-level `{…}` exactly once whether the body is SSE or a JSON array, never
/// split inside a string, and never emit a half-received object.
@Suite("Gemini stream object splitter")
struct GeminiStreamObjectSplitterTests {

  private func split(_ text: String) -> [String] {
    var splitter = GeminiStreamObjectSplitter()
    var objects: [String] = []
    for byte in Array(text.utf8) {
      if let object = splitter.feed(byte) {
        objects.append(String(decoding: object, as: UTF8.self))
      }
    }
    return objects
  }

  private let first = #"{"candidates":[{"content":{"parts":[{"text":"a"}]}}]}"#
  private let second = #"{"candidates":[{"content":{"parts":[{"text":"b"}]},"finishReason":"STOP"}]}"#

  @Test("SSE input yields one object per data line")
  func sseInput() {
    let body = "data: \(first)\n\ndata: \(second)\n\n"
    #expect(split(body) == [first, second])
  }

  @Test("Pretty-printed JSON array input yields the same objects")
  func jsonArrayInput() {
    let body = "[\n  \(first),\n  \(second)\n]\n"
    #expect(split(body) == [first, second])
  }

  @Test("Braces and escaped quotes inside strings do not split an object")
  func bracesInsideStrings() {
    let tricky = #"{"text":"say \"}\" and {not a brace} \\","n":1}"#
    let objects = split("data: \(tricky)\n\ndata: \(first)\n\n")
    #expect(objects == [tricky, first])
  }

  @Test("A trailing partial object is not emitted")
  func trailingPartialIsHeld() {
    let body = "data: \(first)\n\ndata: " + String(second.dropLast(5))
    #expect(split(body) == [first])
  }

  @Test("An object completed across two feeds is emitted once, on the closing brace")
  func objectSpansFeeds() {
    var splitter = GeminiStreamObjectSplitter()
    let bytes = Array(first.utf8)
    var emitted: [Data] = []
    for byte in bytes.dropLast() {
      #expect(splitter.feed(byte) == nil)
    }
    if let object = splitter.feed(bytes.last!) { emitted.append(object) }
    #expect(emitted.count == 1)
    #expect(String(decoding: emitted[0], as: UTF8.self) == first)
  }
}
