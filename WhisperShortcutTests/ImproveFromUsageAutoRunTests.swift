import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Improve from usage auto-run")
struct ImproveFromUsageAutoRunTests {

  @Test("A check a few seconds short of the interval is due; a truncated day count is not")
  func dueUsesElapsedTimeWithSlack() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 20, hour: 12))!
    let intervalDays = 7
    // 30 s short of 7×86400. `dateComponents([.day])` truncates that to 6, so the old
    // `elapsed >= days` check waited until the next daily timer — a day late.
    let almost = now.addingTimeInterval(-(Double(intervalDays) * 86_400 - 30))
    let truncatedDays = calendar.dateComponents([.day], from: almost, to: now).day
    #expect(truncatedDays == 6)
    #expect(
      ImproveFromUsageAutoRunCoordinator.isDue(lastRun: almost, now: now, intervalDays: intervalDays))

    let twoMinutesShort = now.addingTimeInterval(-(Double(intervalDays) * 86_400 - 120))
    #expect(
      !ImproveFromUsageAutoRunCoordinator.isDue(
        lastRun: twoMinutesShort, now: now, intervalDays: intervalDays))
    #expect(ImproveFromUsageAutoRunCoordinator.isDue(lastRun: nil, now: now, intervalDays: intervalDays))
  }

  @Test("Auto-run follows the selected improvement provider, not a Gemini credential")
  func credentialFollowsSelectedModel() {
    #expect(
      ImproveFromUsageAutoRunCoordinator.providerAllowsAutoRun(
        model: .openaiGPT6Sol, hasCredential: { $0 == .openai }))
    // A Gemini key must not unlock a model the user did not select, and must not be required
    // when the selected provider already has its own credential.
    #expect(
      !ImproveFromUsageAutoRunCoordinator.providerAllowsAutoRun(
        model: .openaiGPT6Sol, hasCredential: { $0 == .gemini }))
    #expect(
      ImproveFromUsageAutoRunCoordinator.providerAllowsAutoRun(
        model: .gemini38Flash, hasCredential: { $0 == .gemini }))
    #expect(
      !ImproveFromUsageAutoRunCoordinator.providerAllowsAutoRun(
        model: .claudeHaiku55, hasCredential: { _ in false }))
  }

  @Test("The auto-run date is the start of the run, and a transient failure stamps nothing")
  func stampIsTheStart() {
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(
      AutoPromptImprovementScheduler.autoRunStamp(startedAt: started, everyFocusFailedTransiently: false)
        == started)
    #expect(
      AutoPromptImprovementScheduler.autoRunStamp(startedAt: started, everyFocusFailedTransiently: true)
        == nil)
  }
}
