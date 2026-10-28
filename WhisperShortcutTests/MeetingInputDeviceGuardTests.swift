import CoreAudio
import XCTest

@testable import WhisperShortcut_AppStore

final class MeetingInputDeviceGuardTests: XCTestCase {

  func testBluetoothWithBuiltInSwitches() {
    XCTAssertTrue(
      MeetingInputDeviceGuard.shouldSwitch(
        inputTransport: kAudioDeviceTransportTypeBluetooth, builtInInputAvailable: true))
  }

  func testBluetoothLEWithBuiltInSwitches() {
    XCTAssertTrue(
      MeetingInputDeviceGuard.shouldSwitch(
        inputTransport: kAudioDeviceTransportTypeBluetoothLE, builtInInputAvailable: true))
  }

  func testBluetoothWithoutBuiltInDoesNotSwitch() {
    XCTAssertFalse(
      MeetingInputDeviceGuard.shouldSwitch(
        inputTransport: kAudioDeviceTransportTypeBluetooth, builtInInputAvailable: false))
  }

  func testBuiltInDoesNotSwitch() {
    XCTAssertFalse(
      MeetingInputDeviceGuard.shouldSwitch(
        inputTransport: kAudioDeviceTransportTypeBuiltIn, builtInInputAvailable: true))
  }

  func testUSBDoesNotSwitch() {
    XCTAssertFalse(
      MeetingInputDeviceGuard.shouldSwitch(
        inputTransport: kAudioDeviceTransportTypeUSB, builtInInputAvailable: true))
  }

  func testNilTransportDoesNotSwitch() {
    XCTAssertFalse(
      MeetingInputDeviceGuard.shouldSwitch(inputTransport: nil, builtInInputAvailable: true))
  }
}
