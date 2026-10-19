import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("MCP meeting tools")
struct MCPMeetingToolsTests {

  private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func write(_ dir: URL, _ name: String, _ text: String) throws {
    try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  private let live = "Meeting-2026-10-19-110109"
  private let old = "Meeting-2026-10-18-090000-Budget"
  private let liveText = "[00:05] Speaker A: Hello team\n\n[01:10] Speaker B: Budget is fine\n\n[02:30] Speaker A: Ship it Friday\n"

  private func fixture(liveStem: String? = "Meeting-2026-10-19-110109") throws -> MCPMeetingTools {
    let dir = try makeDir()
    try write(dir, "\(live).txt", liveText)
    try write(dir, "\(old).txt", "[00:10] Speaker A: Über die Straße gehen\n\n[05:00] Speaker B: Quarterly numbers\n")
    try write(dir, "\(old).notes.md", "- decided on café budget")
    try write(dir, "\(old).summary.md", "Summary text")
    return MCPMeetingTools(meetingsDirectory: dir, liveStem: { liveStem })
  }

  @Test("Live transcript without since returns everything and next_since")
  func liveAll() throws {
    let r = try fixture().call(name: "get_live_transcript", arguments: [:])
    #expect(!r.isError)
    #expect(r.text.contains("Hello team"))
    #expect(r.text.contains("Ship it Friday"))
    #expect(r.text.contains("next_since: 02:30"))
  }

  @Test("Live transcript with since returns only the delta")
  func liveDelta() throws {
    let r = try fixture().call(name: "get_live_transcript", arguments: ["since": "01:10"])
    #expect(!r.text.contains("Hello team"))
    #expect(!r.text.contains("Budget is fine"))
    #expect(r.text.contains("Ship it Friday"))
    #expect(r.text.contains("next_since: 02:30"))
  }

  @Test("Nothing new says so")
  func liveNothingNew() throws {
    let r = try fixture().call(name: "get_live_transcript", arguments: ["since": "02:30"])
    #expect(r.text.contains("No new transcript since 02:30"))
  }

  @Test("No live meeting names the latest one")
  func noLive() throws {
    let r = try fixture(liveStem: nil).call(name: "get_live_transcript", arguments: [:])
    #expect(r.text.contains("No meeting is being recorded"))
    #expect(r.text.contains(live))
  }

  @Test("h:mm:ss since is accepted")
  func hourSince() throws {
    let r = try fixture().call(name: "get_live_transcript", arguments: ["since": "0:01:10"])
    #expect(!r.isError)
    #expect(!r.text.contains("Budget is fine"))
  }

  @Test("list_meetings is newest first with flags")
  func list() throws {
    let r = try fixture().call(name: "list_meetings", arguments: [:])
    let liveIdx = try #require(r.text.range(of: live))
    let oldIdx = try #require(r.text.range(of: old))
    #expect(liveIdx.lowerBound < oldIdx.lowerBound)
    let oldLine = r.text.split(separator: "\n").first { $0.contains(old) }.map(String.init) ?? ""
    #expect(oldLine.contains("title: Budget"))
    #expect(oldLine.contains("has_notes: true"))
    #expect(oldLine.contains("has_summary: true"))
    #expect(oldLine.contains("is_live: false"))
    let liveLine = r.text.split(separator: "\n").first { $0.contains(live) }.map(String.init) ?? ""
    #expect(liveLine.contains("is_live: true"))
    #expect(liveLine.contains("duration: 02:30"))
  }

  @Test("list_meetings honors limit")
  func listLimit() throws {
    let r = try fixture().call(name: "list_meetings", arguments: ["limit": 1])
    #expect(r.text.contains(live))
    #expect(!r.text.contains("id: \(old)"))
  }

  @Test("get_meeting parts")
  func getParts() throws {
    let t = try fixture()
    let all = t.call(name: "get_meeting", arguments: ["id": old])
    #expect(all.text.contains("Quarterly numbers"))
    #expect(all.text.contains("café budget"))
    #expect(all.text.contains("Summary text"))
    let notes = t.call(name: "get_meeting", arguments: ["id": old, "part": "notes"])
    #expect(notes.text.contains("café budget"))
    #expect(!notes.text.contains("Quarterly"))
    let since = t.call(name: "get_meeting", arguments: ["id": old, "part": "transcript", "since": "00:10"])
    #expect(since.text.contains("Quarterly"))
    #expect(!since.text.contains("Straße"))
    let until = t.call(name: "get_meeting", arguments: ["id": old, "part": "transcript", "until": "01:00"])
    #expect(until.text.contains("Straße"))
    #expect(!until.text.contains("Quarterly"))
    #expect(t.call(name: "get_meeting", arguments: ["id": old, "until": "soon"]).isError)
  }

  @Test("get_meeting rejects traversal and unknown ids")
  func getRejects() throws {
    let t = try fixture()
    #expect(t.call(name: "get_meeting", arguments: ["id": "../secret"]).isError)
    #expect(t.call(name: "get_meeting", arguments: ["id": "a/b"]).isError)
    let unknown = t.call(name: "get_meeting", arguments: ["id": "Meeting-1999-01-01-000000"])
    #expect(unknown.isError)
    #expect(unknown.text.contains("list_meetings"))
  }

  @Test("search is case and diacritic insensitive")
  func search() throws {
    let t = try fixture()
    let r = t.call(name: "search_meetings", arguments: ["query": "STRASSE"])
    #expect(r.text.contains("Straße"))
    let r2 = t.call(name: "search_meetings", arguments: ["query": "uber die"])
    #expect(r2.text.contains(old))
    #expect(r2.text.contains("[00:10]"))
    let r3 = t.call(name: "search_meetings", arguments: ["query": "CAFE"])
    #expect(r3.text.contains("[notes]"))
    let r4 = t.call(name: "search_meetings", arguments: ["query": "budget"])
    #expect(r4.text.contains(live))
    let a = try #require(r4.text.range(of: live))
    let b = try #require(r4.text.range(of: old))
    #expect(a.lowerBound < b.lowerBound)
  }

  @Test("60k cap keeps the newest part")
  func cap() throws {
    let dir = try makeDir()
    var text = ""
    for i in 0..<400 { text += String(format: "[%02d:%02d] Speaker A: ", i / 60, i % 60) + String(repeating: "x", count: 400) + " end\(i)\n\n" }
    try write(dir, "\(live).txt", text)
    let t = MCPMeetingTools(meetingsDirectory: dir, liveStem: { live })
    let r = t.call(name: "get_live_transcript", arguments: [:])
    #expect(r.text.count < 61_000)
    #expect(r.text.contains("Output cut"))
    #expect(r.text.contains("end399"))
    #expect(!r.text.contains("end0 "))
  }
}
