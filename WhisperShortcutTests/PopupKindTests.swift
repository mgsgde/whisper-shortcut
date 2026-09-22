import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the popup kind table that used to be four independent Bools and two ladders
/// (`setupIcon`, `startAutoHideTimer`).
@Suite("Popup kind")
struct PopupKindTests {

  private let notificationDefault = SettingsDefaults.notificationDuration.rawValue
  private let errorDefault = SettingsDefaults.errorNotificationDuration.rawValue

  private func interval(
    _ kind: PopupKind,
    custom: TimeInterval? = nil,
    savedNotification: TimeInterval = 0,
    savedError: TimeInterval = 0,
    suppressesAutoHide: Bool = false
  ) -> TimeInterval? {
    kind.autoHideInterval(
      customDisplayDuration: custom,
      savedNotificationDuration: savedNotification,
      savedErrorDuration: savedError,
      suppressesAutoHide: suppressesAutoHide
    )
  }

  @Test("Kind maps to the pre-refactor icon, auto-hide duration, and button row")
  func kindTableMatchesPreviousLadders() {
    #expect(PopupKind.success.iconText == "✅")
    #expect(PopupKind.success.hasActionButtons == false)
    #expect(interval(.success) == notificationDefault)

    #expect(PopupKind.info.iconText == "ℹ️")
    #expect(PopupKind.info.hasActionButtons == false)
    #expect(interval(.info) == notificationDefault)

    #expect(PopupKind.cancelled.iconText == "⏸️")
    #expect(PopupKind.cancelled.hasActionButtons == false)
    #expect(interval(.cancelled) == notificationDefault)

    #expect(PopupKind.processing.iconText == "⏳")
    #expect(PopupKind.processing.hasActionButtons == false)
    #expect(interval(.processing) == nil)

    #expect(PopupKind.error.iconText == "")
    #expect(PopupKind.error.hasActionButtons == true)
    #expect(interval(.error) == errorDefault)
  }

  @Test("A positive custom duration overrides the saved one, except where no timer runs")
  func customDurationAndSuppression() {
    #expect(interval(.success, custom: 4) == 4)
    #expect(interval(.error, custom: 4) == 4)
    #expect(interval(.info, custom: 0) == notificationDefault)
    #expect(interval(.processing, custom: 4) == nil)
    #expect(interval(.error, custom: 4, suppressesAutoHide: true) == nil)
  }

  @Test("Saved durations apply only when they are a NotificationDuration")
  func savedDurationMustBeAKnownCase() {
    #expect(interval(.success, savedNotification: NotificationDuration.fiveSeconds.rawValue) == 5)
    #expect(interval(.error, savedError: NotificationDuration.tenSeconds.rawValue) == 10)
    #expect(interval(.success, savedNotification: 4) == notificationDefault)
    #expect(interval(.error, savedError: 4) == errorDefault)
    #expect(interval(.cancelled, savedNotification: NotificationDuration.twoSeconds.rawValue) == 2)
  }
}
