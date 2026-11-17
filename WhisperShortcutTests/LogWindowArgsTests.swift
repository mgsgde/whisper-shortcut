import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Log window args")
struct LogWindowArgsTests {
  private let now = UserContextLog.timestamp("2026-11-02T12:00:00Z")!

  private func parse(_ args: [String: Any]) -> (value: LogWindowArgs?, error: String?) {
    LogWindowArgs.parse(args, defaultLimit: 15, maxLimit: 30, now: now)
  }

  @Test("limit defaults and clamps low and high")
  func limitClamping() {
    #expect(parse([:]).value?.limit == 15)
    #expect(parse(["limit": 0]).value?.limit == 1)
    #expect(parse(["limit": -5]).value?.limit == 1)
    #expect(parse(["limit": 500]).value?.limit == 30)
    #expect(parse(["limit": 7]).value?.limit == 7)
  }

  @Test("since accepts a date, an ISO timestamp and relative spans")
  func sinceForms() throws {
    #expect(parse([:]).value?.since == nil)
    #expect(parse(["since": "  "]).value?.since == nil)
    #expect(parse(["since": ""]).value?.since == nil)
    #expect(parse(["since": "2026-10-01"]).value?.since != nil)
    #expect(parse(["since": "2026-10-01T08:00:00Z"]).value?.since == UserContextLog.timestamp("2026-10-01T08:00:00Z"))
    let days = try #require(parse(["since": "14d"]).value?.since)
    #expect(abs(now.timeIntervalSince(days) - 14 * 86_400) < 3_700)
    let hours = try #require(parse(["since": "48h"]).value?.since)
    #expect(abs(now.timeIntervalSince(hours) - 48 * 3_600) < 3_700)
  }

  @Test("an unreadable since returns the exact error")
  func invalidSince() {
    let result = parse(["since": "last tuesday"])
    #expect(result.value == nil)
    #expect(result.error == "since must be a date (2026-10-01), an ISO-8601 timestamp, or a relative 14d / 48h.")
  }

  @Test("isAtOrAfter and cap")
  func helpers() {
    let since = UserContextLog.timestamp("2026-10-01T00:00:00Z")
    #expect(LogWindowArgs.isAtOrAfter(since: nil, ts: "garbage"))
    #expect(LogWindowArgs.isAtOrAfter(since: since, ts: "2026-10-02T00:00:00Z"))
    #expect(!LogWindowArgs.isAtOrAfter(since: since, ts: "2026-09-30T00:00:00Z"))
    #expect(!LogWindowArgs.isAtOrAfter(since: since, ts: "garbage"))
    #expect(LogWindowArgs.cap("abcdef", to: 3) == "abc…")
    #expect(LogWindowArgs.cap("abc", to: 3) == "abc")
  }
}
