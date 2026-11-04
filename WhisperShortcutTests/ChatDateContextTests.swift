import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The one date/time line every prompt gets. These tests pin the *rendering* (weekday, date, time,
/// zone) with a fixed `Date`, `TimeZone` and `Locale` — the helper takes them as parameters exactly
/// so this needs no clock, no machine time zone and no user locale.
@Suite("Chat date context")
struct ChatDateContextTests {

  /// Wednesday, 4 November 2026, 17:42:00 UTC.
  private static let fixedDate = Date(timeIntervalSince1970: 1_793_814_120)

  private static let berlin = TimeZone(identifier: "Europe/Berlin")!
  private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
  private static let english = Locale(identifier: "en_US")
  private static let german = Locale(identifier: "de_DE")

  @Test("The line carries weekday, date, time and time zone identifier")
  func lineCarriesAllFourFields() {
    let line = ChatDateContext.line(
      now: Self.fixedDate, timeZone: Self.berlin, locale: Self.english)

    #expect(line.hasPrefix("Current date and time: "))
    #expect(line.contains("Wednesday"))
    #expect(line.contains("November"))
    #expect(line.contains("4"))
    #expect(line.contains("2026"))
    // Berlin is UTC+1 in November, so 17:42 UTC is 18:42 local.
    #expect(line.contains("18:42"))
    #expect(line.contains("Europe/Berlin"))
    #expect(line.hasSuffix("."))
  }

  @Test("A different time zone renders a different time")
  func timeZoneChangesRenderedTime() {
    let berlinLine = ChatDateContext.line(
      now: Self.fixedDate, timeZone: Self.berlin, locale: Self.english)
    let tokyoLine = ChatDateContext.line(
      now: Self.fixedDate, timeZone: Self.tokyo, locale: Self.english)

    #expect(berlinLine.contains("18:42"))
    #expect(tokyoLine.contains("02:42"))
    #expect(tokyoLine.contains("Asia/Tokyo"))
    #expect(berlinLine != tokyoLine)
  }

  @Test("A different locale changes the language of the weekday")
  func localeChangesWeekdayLanguage() {
    let englishLine = ChatDateContext.line(
      now: Self.fixedDate, timeZone: Self.berlin, locale: Self.english)
    let germanLine = ChatDateContext.line(
      now: Self.fixedDate, timeZone: Self.berlin, locale: Self.german)

    #expect(englishLine.contains("Wednesday"))
    #expect(!englishLine.contains("Mittwoch"))
    #expect(germanLine.contains("Mittwoch"))
    #expect(germanLine.contains("November"))
    // The time and zone stay machine-readable in every locale.
    #expect(germanLine.contains("18:42"))
    #expect(germanLine.contains("Europe/Berlin"))
  }

  @Test("A custom label dates a moment that is not now")
  func customLabelIsUsed() {
    let line = ChatDateContext.line(
      label: "Meeting started", at: Self.fixedDate, timeZone: Self.berlin, locale: Self.english)

    #expect(line.hasPrefix("Meeting started: Wednesday, November 4, 2026"))
    #expect(line.contains("18:42"))
  }

  @Test("A meeting stem parses to the meeting's date and time")
  func meetingStemParsesToDate() throws {
    let stem = "Meeting-2026-11-04-143000"
    let parsed = try #require(MeetingListService.date(fromStem: stem))

    // `date(fromStem:)` reads the stem in the machine's time zone, so compare components there.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: parsed)
    #expect(parts.year == 2026)
    #expect(parts.month == 11)
    #expect(parts.day == 4)
    #expect(parts.hour == 14)
    #expect(parts.minute == 30)
    #expect(parts.second == 0)

    let line = try #require(
      ChatDateContext.meetingLine(stem: stem, timeZone: Self.berlin, locale: Self.english))
    #expect(line.hasPrefix("Meeting date and time: Wednesday, November 4, 2026"))
    #expect(line.contains("Europe/Berlin"))
  }

  @Test("An unparseable stem yields no date line")
  func unparseableStemYieldsNoLine() {
    #expect(MeetingListService.date(fromStem: "not-a-meeting") == nil)
    #expect(MeetingListService.date(fromStem: "Meeting-2026-13-45-999999") == nil)
    #expect(ChatDateContext.meetingLine(stem: "not-a-meeting") == nil)
    #expect(ChatDateContext.meetingLine(stem: "Meeting-2026-13-45-999999") == nil)
  }
}
