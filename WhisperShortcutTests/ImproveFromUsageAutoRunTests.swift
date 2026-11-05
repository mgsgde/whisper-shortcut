import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Improve from usage auto-run")
struct ImproveFromUsageAutoRunTests {

  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let intervalDays = 7

  private func lastRun(shortOfIntervalBy seconds: TimeInterval) -> Date {
    now.addingTimeInterval(-(Double(intervalDays) * 86_400 - seconds))
  }

  @Test("A check up to half a day short of the interval is due; a day short is not")
  func dueToleratesTimerMisalignment() {
    func due(_ last: Date?) -> Bool {
      ImproveFromUsageAutoRunCoordinator.isDue(lastRun: last, now: now, intervalDays: intervalDays)
    }
    // `dateComponents([.day])` truncated all of these to 6 days and waited another 24 h.
    #expect(due(lastRun(shortOfIntervalBy: 30)))
    // The daily timer is anchored to launch, so a run started at another time of day (a Settings
    // interval change, a later launch) is out of step with it by up to 24 h. The nearest check
    // on either side of the due time must run it.
    #expect(due(lastRun(shortOfIntervalBy: 6 * 3_600)))
    #expect(due(lastRun(shortOfIntervalBy: 11 * 3_600)))
    #expect(!due(lastRun(shortOfIntervalBy: 13 * 3_600)))
    #expect(!due(lastRun(shortOfIntervalBy: 24 * 3_600)))
    #expect(due(now.addingTimeInterval(-Double(intervalDays) * 86_400 - 3_600)))
    #expect(due(nil))
  }

  @Test("Daily ticks anchored to launch run the job within 12 h of the due time, then every period")
  func nextTickAfterMisalignedRun() {
    // Run started at t0; the launch-anchored timer ticks 19 h later and every 24 h after that.
    let t0 = now
    let firstTick = t0.addingTimeInterval(19 * 3_600)
    let dueAt = t0.addingTimeInterval(Double(intervalDays) * 86_400)
    // Tick on day 6 (+19 h) is 5 h short of due: runs, instead of waiting for day 7 (+19 h).
    let dayBeforeDue = firstTick.addingTimeInterval(Double(intervalDays - 1) * 86_400)
    #expect(dayBeforeDue < dueAt)
    #expect(
      ImproveFromUsageAutoRunCoordinator.isDue(lastRun: t0, now: dayBeforeDue, intervalDays: intervalDays))
    // The tick before that is 29 h short and does not.
    #expect(
      !ImproveFromUsageAutoRunCoordinator.isDue(
        lastRun: t0, now: dayBeforeDue.addingTimeInterval(-86_400), intervalDays: intervalDays))
  }
}
