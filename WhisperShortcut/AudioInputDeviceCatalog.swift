//
//  AudioInputDeviceCatalog.swift
//  WhisperShortcut
//
//  CoreAudio enumeration of the Mac's input devices (microphones).
//
//  AVAudioRecorder — which every recorder in this app uses — has no device parameter on
//  macOS and always captures from the system default input. Naming that device on the
//  recording pill is step 1 of the microphone picker (plans/implementer-queue.md row 68):
//  most "wrong headset" cases are resolved the moment the user sees which mic is live.
//  Step 2 (choosing a device in Settings) will build on the same catalog.
//

import AudioToolbox
import CoreAudio
import Foundation

enum AudioInputDeviceCatalog {

  /// One physical input device. `uid` is the stable CoreAudio identifier (it survives
  /// reboots; the numeric `id` does not) and is what a future device picker must persist.
  struct InputDevice: Equatable, Identifiable {
    var id: AudioObjectID
    let uid: String
    let name: String
  }

  /// The device macOS currently records from, or nil when CoreAudio has no usable answer
  /// (e.g. no input device exists at all). The name is the raw CoreAudio device name —
  /// never a made-up label — so it matches what System Settings shows.
  static func defaultInputDevice() -> InputDevice? {
    guard let deviceID = readDefaultInputDevice() else { return nil }
    return device(id: deviceID)
  }

  /// Convenience for callers that only display the name.
  static func defaultInputDeviceName() -> String? {
    defaultInputDevice()?.name
  }

  /// Every input device with at least one input channel, aggregate and virtual drivers
  /// (BlackHole, Zoom, Teams) filtered out: they are loopback routes, not microphones,
  /// and a microphone picker must not offer them.
  static func availableDevices() -> [InputDevice] {
    guard let ids = readAllDeviceIDs() else { return [] }
    return ids.compactMap { device(id: $0) }.filter { $0.name.isEmpty == false }
  }

  // MARK: - Property reads (same shape as OutputRoute in SystemAudioCapture.swift)

  private static func device(id: AudioObjectID) -> InputDevice? {
    guard let uid = readDeviceUID(id), let name = readDeviceName(id),
      inputChannelCount(id) > 0, isPhysical(id)
    else { return nil }
    return InputDevice(id: id, uid: uid, name: name)
  }

  private static func readAllDeviceIDs() -> [AudioObjectID]? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var count = UInt32(0)
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &count)
    guard status == noErr, count > 0 else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(count) / MemoryLayout<AudioObjectID>.size)
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &count, &ids)
    guard status == noErr else { return nil }
    return ids
  }

  private static func readDefaultInputDevice() -> AudioObjectID? {
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

  private static func readDeviceName(_ deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  private static func readDeviceUID(_ deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  /// Summed channel count of the device's input streams. Zero means the device cannot
  /// record (an output-only device), so it is not a microphone candidate.
  private static func inputChannelCount(_ deviceID: AudioObjectID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    guard status == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let readStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
    guard readStatus == noErr else { return 0 }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    var channels: UInt32 = 0
    for buffer in buffers {
      channels += buffer.mNumberChannels
    }
    return channels
  }

  /// True unless the device is an aggregate or otherwise virtual route. Those are loopback
  /// drivers, not microphones, and must not appear in a microphone picker.
  private static func isPhysical(_ deviceID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr else { return false }
    return value != kAudioDeviceTransportTypeVirtual
  }
}
