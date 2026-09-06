import AppKit
import Testing

@testable import WhisperShortcut_AppStore

/// Pins that the suite runs inside an inert test host, not inside the menu bar app.
///
/// `FullAppDelegate` builds a status item, an Edit menu and — on a container that has never
/// completed onboarding, which is every CI runner — the Welcome window, then ignores SIGTERM and
/// answers `applicationShouldTerminate` with `.terminateCancel`. On a runner with no usable render
/// server that combination turns a fully green run red: the main thread wedges on a CoreAnimation
/// fence, nothing can stop the host, and the job dies in "** BUILD INTERRUPTED **" seconds after
/// the last test passed — with the step marked *cancelled*, so the crash-report and xcresult steps
/// are skipped too and the failure carries no evidence.
///
/// None of it reproduces on a developer Mac, so this is the only place the wiring gets checked.
@Suite("Test host lifecycle")
struct TestHostLifecycleTests {

  @Test("The app knows it is hosting a test run")
  func detectsTestHost() {
    #expect(isRunningUnderTest)
  }

  @Test("The test host runs the inert delegate, not the menu bar app")
  @MainActor
  func testHostUsesInertDelegate() {
    #expect(NSApplication.shared.delegate is TestHostAppDelegate)
  }
}
