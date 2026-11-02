import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// PATCH merges nested objects, so switching an event between timed and all-day must null the
/// fields of the previous form or Google rejects the result (both `date` and `dateTime` set).
@Suite("Google Calendar update body")
struct GoogleCalendarUpdateBodyTests {

  private func field(_ body: [String: Any], _ key: String) throws -> [String: Any] {
    try #require(body[key] as? [String: Any])
  }

  @Test("Timed → all-day nulls dateTime and timeZone on start and end")
  func timedToAllDay() async throws {
    let body = try await GoogleCalendarAPIClient().updateEventBody(
      startISO: "2026-11-05", endISO: "2026-11-06", timeZone: "Europe/Berlin", allDay: true)
    for key in ["start", "end"] {
      let f = try field(body, key)
      #expect(f["date"] as? String != nil)
      #expect(f["dateTime"] is NSNull)
      #expect(f["timeZone"] is NSNull)
    }
    #expect(try field(body, "start")["date"] as? String == "2026-11-05")
  }

  @Test("All-day → timed nulls date on start and end")
  func allDayToTimed() async throws {
    let body = try await GoogleCalendarAPIClient().updateEventBody(
      startISO: "2026-11-05T10:00:00", endISO: "2026-11-05T11:00:00",
      timeZone: "Europe/Berlin", allDay: false)
    for key in ["start", "end"] {
      let f = try field(body, key)
      #expect(f["dateTime"] as? String != nil)
      #expect(f["timeZone"] as? String == "Europe/Berlin")
      #expect(f["date"] is NSNull)
    }
  }

  @Test("The body serializes with explicit JSON nulls")
  func serializesNulls() async throws {
    let body = try await GoogleCalendarAPIClient().updateEventBody(
      startISO: "2026-11-05", endISO: "2026-11-06", timeZone: "UTC", allDay: true)
    let json = try #require(String(data: JSONSerialization.data(withJSONObject: body), encoding: .utf8))
    #expect(json.contains("\"dateTime\":null"))
    #expect(json.contains("\"timeZone\":null"))
  }

  @Test("Updates without timing fields do not touch start or end")
  func noTimingFields() async throws {
    let body = try await GoogleCalendarAPIClient().updateEventBody(summary: "Renamed")
    #expect(body["start"] == nil && body["end"] == nil)
    #expect(body["summary"] as? String == "Renamed")
  }
}
