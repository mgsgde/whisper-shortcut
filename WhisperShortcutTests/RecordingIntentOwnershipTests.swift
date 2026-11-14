import XCTest
@testable import WhisperShortcut_AppStore

final class RecordingIntentOwnershipTests: XCTestCase {
  func testFreshTranscriptionIntentDoesNotOwnFinishedAudio() {
    let intent = MenuBarController.RecordingIntent(target: .mode(.transcription))
    XCTAssertFalse(intent.ownsFinishedAudio)
    XCTAssertEqual(intent.pendingMode, .transcription)
  }

  func testStartedCaptureOwnsFinishedAudio() {
    var intent = MenuBarController.RecordingIntent(target: .mode(.transcription))
    intent.captureStarted = true
    XCTAssertTrue(intent.ownsFinishedAudio)
  }

  func testDiscardBeforeCaptureOwnsFinishedAudio() {
    var intent = MenuBarController.RecordingIntent(target: .mode(.transcription))
    intent.captureStarted = false
    intent.discardOnFinish = true
    XCTAssertTrue(intent.ownsFinishedAudio)
  }

  func testMeetingSegmentWaitingForMicDoesNotOwnFinishedAudio() {
    let intent = MenuBarController.RecordingIntent(target: .meetingSegment(.dictation))
    XCTAssertFalse(intent.captureStarted)
    XCTAssertFalse(intent.discardOnFinish)
    XCTAssertFalse(intent.ownsFinishedAudio)
  }
}
