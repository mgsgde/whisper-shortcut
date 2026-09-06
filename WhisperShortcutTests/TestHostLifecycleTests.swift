import AppKit
import Testing

@testable import WhisperShortcut_AppStore

/// Pins the two properties that let xcodebuild shut the test host down.
///
/// The host is the real menu bar app: it opens the Welcome window on a container that has never
/// completed onboarding, ignores SIGTERM, and answers `applicationShouldTerminate` with
/// `.terminateCancel`. On a CI runner that combination turns a fully green run red — the window's
/// render fence never signals, the main thread wedges, nothing can deliver the termination
/// signal, and the job ends in "** BUILD INTERRUPTED **" seconds after the last test passed
/// (v8.06…v8.11 never published a DMG this way). All of it hangs off `isRunningUnderTest`, and
/// none of it fails on a developer Mac, so without these two tests the regression would come back
/// invisibly.
@Suite("Test host lifecycle")
struct TestHostLifecycleTests {

  @Test("The app knows it is hosting a test run")
  func detectsTestHost() {
    #expect(isRunningUnderTest)
  }

  @Test("A test host agrees to terminate instead of surviving as a menu bar app")
  @MainActor
  func testHostTerminatesOnRequest() {
    let delegate = FullAppDelegate()
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
  }
}
