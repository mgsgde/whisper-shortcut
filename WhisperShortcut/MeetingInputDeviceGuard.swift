import CoreAudio
import Foundation

/// Bluetooth earbuds used as the default input put the whole headset into call mode (HFP, 16 kHz),
/// and the Core Audio process tap then captures garbage. While a meeting mixes in the Mac's sound,
/// this switches the system default input to the built-in microphone and puts the original back
/// when the meeting ends.
final class MeetingInputDeviceGuard {

  /// Pure decision, separated from the Core Audio reads so it is testable.
  static func shouldSwitch(inputTransport: UInt32?, builtInInputAvailable: Bool) -> Bool {
    guard let inputTransport, builtInInputAvailable else { return false }
    return inputTransport == kAudioDeviceTransportTypeBluetooth
      || inputTransport == kAudioDeviceTransportTypeBluetoothLE
  }

  /// UID of the device that was the default input before we switched.
  private var originalDeviceUID: String?
  /// The built-in device we set as default input.
  private var switchedToDeviceID: AudioObjectID?

  func applyIfNeeded() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let current = Self.defaultInputDevice() else { return }
    let builtIn = Self.firstBuiltInInputDevice()
    guard
      Self.shouldSwitch(
        inputTransport: Self.transportType(current), builtInInputAvailable: builtIn != nil),
      let builtIn, builtIn != current
    else { return }

    let oldName = Self.deviceName(current) ?? "?"
    let newName = Self.deviceName(builtIn) ?? "?"
    let oldUID = Self.deviceUID(current)
    let status = Self.setDefaultInputDevice(builtIn)
    guard status == noErr else {
      DebugLogger.logError(
        "LIVE-MEETING: could not switch input from \(oldName) to \(newName) (OSStatus \(status))")
      return
    }
    if originalDeviceUID == nil { originalDeviceUID = oldUID }
    switchedToDeviceID = builtIn
    DebugLogger.log(
      "LIVE-MEETING: input \(oldName) is Bluetooth; using \(newName) so the earbuds stay out of call mode"
    )
  }

  func restore() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let switched = switchedToDeviceID else { return }
    let uid = originalDeviceUID
    originalDeviceUID = nil
    switchedToDeviceID = nil

    guard Self.defaultInputDevice() == switched else {
      DebugLogger.log("LIVE-MEETING: input was changed during the meeting; not restoring it")
      return
    }
    guard let uid, let original = Self.deviceID(forUID: uid) else {
      DebugLogger.log("LIVE-MEETING: original input device is gone; not restoring it")
      return
    }
    let status = Self.setDefaultInputDevice(original)
    if status == noErr {
      DebugLogger.log("LIVE-MEETING: input restored to \(Self.deviceName(original) ?? "?")")
    } else {
      DebugLogger.logError("LIVE-MEETING: could not restore input device (OSStatus \(status))")
    }
  }

  // MARK: Core Audio reads

  private static func defaultInputDevice() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private static func setDefaultInputDevice(_ deviceID: AudioObjectID) -> OSStatus {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value = deviceID
    return AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
      UInt32(MemoryLayout<AudioObjectID>.size), &value)
  }

  private static func allDevices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var devices = [AudioObjectID](
      repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
    else { return [] }
    return devices
  }

  private static func hasInputStreams(_ deviceID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
  }

  private static func firstBuiltInInputDevice() -> AudioObjectID? {
    allDevices().first {
      transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasInputStreams($0)
    }
  }

  private static func transportType(_ deviceID: AudioObjectID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
    else { return nil }
    return value
  }

  private static func stringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  private static func deviceName(_ deviceID: AudioObjectID) -> String? {
    stringProperty(deviceID, selector: kAudioObjectPropertyName)
  }

  private static func deviceUID(_ deviceID: AudioObjectID) -> String? {
    stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
  }

  private static func deviceID(forUID uid: String) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafePointer(to: &cfUID) { qualifier in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<CFString>.size), qualifier, &size, &deviceID)
    }
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }
}
