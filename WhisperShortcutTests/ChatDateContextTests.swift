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
  private static let english = Locale(identifier: "en_US")

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

  @Test("The prompt prefix carries the date but no clock time, so it stays cacheable")
  func stableLineHasNoClockTime() {
    let early = ChatDateContext.stableLine(
      now: Self.fixedDate, timeZone: Self.berlin, locale: Self.english)
    let later = ChatDateContext.stableLine(
      now: Self.fixedDate.addingTimeInterval(3 * 3600), timeZone: Self.berlin, locale: Self.english)

    #expect(early.hasPrefix("Current date: "))
    #expect(early.contains("Wednesday"))
    #expect(early.contains("November 4, 2026"))
    #expect(early.contains("Europe/Berlin"))
    #expect(!early.contains("18:42"))
    // Same day, three hours apart: byte-identical, which is what keeps the provider cache warm.
    #expect(early == later)
  }

  @Test("The clock time is a separate line for the volatile tail")
  func timeOfDayLineCarriesTheClock() {
    let line = ChatDateContext.timeOfDayLine(
      now: Self.fixedDate, timeZone: Self.berlin, locale: Self.english)

    #expect(line.hasPrefix("Current time: "))
    #expect(line.contains("18:42"))
    #expect(line.contains("Europe/Berlin"))
    #expect(!line.contains("Wednesday"))
  }

  @Test("A non-Gregorian locale still renders the Gregorian date")
  func nonGregorianLocaleKeepsGregorianDate() {
    // Thai defaults to the Buddhist calendar, where 2026 is 2569. The prompt must say 2026: the
    // model reasons about the same year the user's files and mail are dated in.
    let line = ChatDateContext.stableLine(
      now: Self.fixedDate, timeZone: Self.berlin, locale: Locale(identifier: "th_TH"))

    #expect(line.contains("2026"))
    #expect(!line.contains("2569"))
  }
}
