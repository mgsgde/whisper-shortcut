import XCTest

@testable import WhisperShortcut_AppStore

/// Log filenames must stay Gregorian `yyyy-MM-dd` even when the Mac's calendar
/// is Buddhist or Japanese. No filesystem access: this only formats a fixed date.
final class LogFileDateFormatterTests: XCTestCase {
  func testInteractionLogFileDateIsGregorianYearMonthDay() throws {
    let formatter = UserContextLog.fileNameDateFormatter
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = formatter.timeZone
    let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))
    XCTAssertEqual(formatter.string(from: try XCTUnwrap(date)), "2026-10-21")
  }
}
