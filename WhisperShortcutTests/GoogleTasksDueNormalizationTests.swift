import Testing
@testable import WhisperShortcut_AppStore

@Suite("Google Tasks due normalisation")
struct GoogleTasksDueNormalizationTests {

  @Test("A full RFC3339 date-time passes through")
  func fullRFC3339() {
    #expect(
      GoogleTasksAPIClient.normalizedRFC3339Due("2026-11-10T09:00:00+01:00")
        == "2026-11-10T09:00:00+01:00")
    #expect(
      GoogleTasksAPIClient.normalizedRFC3339Due("2026-11-10T09:00:00.000Z")
        == "2026-11-10T09:00:00.000Z")
  }

  @Test("A date-only value becomes midnight UTC")
  func dateOnly() {
    #expect(GoogleTasksAPIClient.normalizedRFC3339Due("2026-11-10") == "2026-11-10T00:00:00.000Z")
    #expect(GoogleTasksAPIClient.normalizedRFC3339Due("  2026-11-10  ") == "2026-11-10T00:00:00.000Z")
  }

  @Test("A local datetime without an offset keeps the date")
  func localDateTimeWithoutOffset() {
    #expect(
      GoogleTasksAPIClient.normalizedRFC3339Due("2026-11-10T09:00:00")
        == "2026-11-10T00:00:00.000Z")
    #expect(
      GoogleTasksAPIClient.normalizedRFC3339Due("2026-11-10 09:00:00")
        == "2026-11-10T00:00:00.000Z")
  }

  @Test("Garbage is rejected")
  func garbage() {
    #expect(GoogleTasksAPIClient.normalizedRFC3339Due("not-a-date") == nil)
    #expect(GoogleTasksAPIClient.normalizedRFC3339Due("") == nil)
    #expect(GoogleTasksAPIClient.normalizedRFC3339Due("11/10/2026") == nil)
  }
}
