import CoreAudio
import XCTest
@testable import WhisperShortcut_AppStore

/// `resolve` is pure. `selectedUID` is the UserDefaults round-trip; tearDown puts back
/// whatever this process had stored so a later test does not inherit "X".
final class MicrophoneSelectionTests: XCTestCase {
  private var hadUID = false
  private var previousUID: String?

  override func setUp() {
    super.setUp()
    let key = UserDefaultsKeys.selectedMicrophoneUID
    if let stored = UserDefaults.standard.string(forKey: key) {
      hadUID = true
      previousUID = stored
    } else {
      hadUID = false
      previousUID = nil
    }
  }

  override func tearDown() {
    let key = UserDefaultsKeys.selectedMicrophoneUID
    if hadUID {
      UserDefaults.standard.set(previousUID, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
    super.tearDown()
  }

  func testNilUIDIsSystemDefault() {
    let mic = device(uid: "built-in")
    XCTAssertEqual(
      MicrophoneSelection.resolve(selectedUID: nil, available: [mic]), .systemDefault)
  }

  func testEmptyUIDIsSystemDefault() {
    let mic = device(uid: "built-in")
    XCTAssertEqual(
      MicrophoneSelection.resolve(selectedUID: "", available: [mic]), .systemDefault)
  }

  func testPresentUIDResolvesToThatDevice() {
    let mic = device(uid: "usb-headset", name: "Headset")
    let other = device(uid: "built-in", name: "MacBook Microphone", id: 2)
    XCTAssertEqual(
      MicrophoneSelection.resolve(selectedUID: "usb-headset", available: [other, mic]),
      .device(mic))
  }

  func testAbsentUIDIsMissing() {
    let mic = device(uid: "built-in")
    XCTAssertEqual(
      MicrophoneSelection.resolve(selectedUID: "unplugged", available: [mic]),
      .missing(uid: "unplugged"))
  }

  func testSelectedUIDRoundTrip() {
    MicrophoneSelection.selectedUID = "X"
    XCTAssertEqual(MicrophoneSelection.selectedUID, "X")
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedMicrophoneUID), "X")

    MicrophoneSelection.selectedUID = nil
    XCTAssertNil(MicrophoneSelection.selectedUID)
    XCTAssertNil(UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedMicrophoneUID))
  }

  private func device(
    uid: String, name: String = "Mic", id: AudioObjectID = 1
  ) -> AudioInputDeviceCatalog.InputDevice {
    AudioInputDeviceCatalog.InputDevice(id: id, uid: uid, name: name)
  }
}
