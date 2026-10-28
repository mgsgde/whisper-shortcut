//
//  SystemAudioCapture.swift
//  WhisperShortcut
//
//  Captures the audio the Mac is playing out loud (the other side of an online meeting) via a
//  Core Audio process tap, so it can be mixed into the meeting recording alongside the
//  microphone. Only meaningful through built-in/HDMI/DisplayPort/AirPlay speakers — see
//  `OutputRoute.isLikelySpeaker` — otherwise it would be recording headphone audio nobody but
//  the user hears.
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - OutputRoute

/// The Mac's current default output device, and whether it is the kind of route (speakers, not
/// headphones) where capturing system audio makes sense for a meeting recording.
struct OutputRoute: Equatable {
  let deviceName: String
  let transportType: UInt32
  let dataSource: UInt32?

  /// Headphone data source on a built-in device ('hdpn'). Not a CoreAudio API constant — these
  /// codes are device-specific values, not part of the transport-type enum.
  private static let headphoneDataSource: UInt32 = 0x6864_706e
  /// Speaker data source on a built-in device ('ispk').
  private static let speakerDataSource: UInt32 = 0x6973_706b

  var isLikelySpeaker: Bool {
    Self.isLikelySpeaker(transportType: transportType, dataSource: dataSource)
  }

  static func isLikelySpeaker(transportType: UInt32, dataSource: UInt32?) -> Bool {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn:
      guard let dataSource else { return true }
      return dataSource == speakerDataSource
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
      kAudioDeviceTransportTypeAirPlay:
      return true
    default:
      return false
    }
  }

  /// Reads the system default output device. Nil if there is none; the device name is empty
  /// (never a made-up label) if that one property read fails.
  static func current() -> OutputRoute? {
    guard let deviceID = Self.readDefaultOutputDevice() else { return nil }
    let name = Self.readDeviceName(deviceID) ?? ""
    let transport = Self.readTransportType(deviceID) ?? 0
    let dataSource = Self.readDataSource(deviceID)
    return OutputRoute(deviceName: name, transportType: transport, dataSource: dataSource)
  }

  // MARK: Private property reads

  fileprivate static func readDefaultOutputDevice() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

  private static func readTransportType(_ deviceID: AudioObjectID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr else { return nil }
    return value
  }

  private static func readDataSource(_ deviceID: AudioObjectID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDataSource,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(deviceID, &address) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr else { return nil }
    return value
  }

  fileprivate static func readDeviceUID(_ deviceID: AudioObjectID) -> String? {
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
}

// MARK: - SystemAudioPermissionHeuristic

/// macOS has no API to ask directly whether the "audio recording" permission behind a process
/// tap was denied; a denied tap just silently yields zeros forever. This infers it: if another
/// process is audibly playing audio for a sustained stretch and the tap has never once seen a
/// non-zero sample, permission is the likely explanation.
struct SystemAudioPermissionHeuristic {
  var threshold: TimeInterval = 8
  private(set) var othersPlayingSeconds: TimeInterval = 0

  /// Cumulative, not continuous: a quiet moment in an ongoing meeting (someone pauses) does not
  /// reset the accumulator, only real captured audio does.
  mutating func tick(dt: TimeInterval, othersPlaying: Bool, hasSeenNonZero: Bool) -> Bool {
    if hasSeenNonZero {
      othersPlayingSeconds = 0
      return false
    }
    guard othersPlaying else { return false }
    othersPlayingSeconds += dt
    return othersPlayingSeconds >= threshold
  }
}

// MARK: - SystemAudioCapture

/// Owns one Core Audio process tap + private aggregate device that captures everything the Mac
/// plays out loud, except this app's own output. Main-thread only; the IO callback runs on its
/// own dedicated queue and only touches pre-allocated scratch memory and the thread-safe
/// `SystemAudioBuffer`.
final class SystemAudioCapture {

  let buffer = SystemAudioBuffer()
  var onOutputRouteChange: ((OutputRoute?) -> Void)?
  var onPermissionSuspectedChange: ((Bool) -> Void)?
  private(set) var isRunning = false

  private let queue = DispatchQueue(
    label: "com.magnusgoedde.whispershortcut.meeting-system-audio", qos: .userInteractive)

  private var ownProcessObjectID = AudioObjectID(kAudioObjectUnknown)
  private var processTapID = AudioObjectID(kAudioObjectUnknown)
  private var tapUUID: UUID?
  private var tapFormat = AudioStreamBasicDescription()
  private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var skipChannelCount = 0
  private var outputDeviceNameAtStart = ""

  private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
  private var restartInProgress = false

  private var timer: Timer?
  private var heuristic = SystemAudioPermissionHeuristic()
  private var permissionSuspected = false

  private var scratch: [Float] = []
  private var simulateDenied = false

  deinit {
    if Thread.isMainThread {
      stop()
    } else {
      DispatchQueue.main.sync {
        stop()
      }
    }
  }

  // MARK: Start / stop

  func start() throws {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !isRunning else { return }

    #if DEBUG
      simulateDenied = ProcessInfo.processInfo.environment["WS_SIMULATE_SYSTEM_AUDIO_DENIED"] == "1"
    #endif
    scratch = [Float](repeating: 0, count: 32_768)

    try setUpCaptureGraph()

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.handleDefaultOutputDeviceChanged()
    }
    let listenerStatus = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listenerBlock)
    guard listenerStatus == noErr else {
      DebugLogger.logError(
        "SYSTEM-AUDIO: AudioObjectAddPropertyListenerBlock failed (\(listenerStatus))")
      teardownCaptureGraph()
      throw NSError(domain: "SystemAudioCapture", code: Int(listenerStatus))
    }
    defaultOutputListenerBlock = listenerBlock

    isRunning = true
    heuristic = SystemAudioPermissionHeuristic()
    permissionSuspected = false

    let newTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.handleTick()
    }
    RunLoop.main.add(newTimer, forMode: .common)
    timer = newTimer

    onOutputRouteChange?(OutputRoute.current())

    let skipNote = skipChannelCount > 0 ? ", skipped \(skipChannelCount) leading ch" : ""
    DebugLogger.logAudio(
      "SYSTEM-AUDIO: started tap \(Int(tapFormat.mSampleRate)) Hz, "
        + "\(Int(tapFormat.mChannelsPerFrame)) ch, output \(outputDeviceNameAtStart)\(skipNote)")
  }

  /// Idempotent; never clears `buffer` (the transcript pipeline still needs what was already
  /// captured once recording stops).
  func stop() {
    let wasRunning = isRunning
    isRunning = false

    timer?.invalidate()
    timer = nil

    if let block = defaultOutputListenerBlock {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
      defaultOutputListenerBlock = nil
    }

    teardownCaptureGraph()

    if wasRunning {
      DebugLogger.logAudio("SYSTEM-AUDIO: stopped")
    }
  }

  // MARK: Capture graph

  /// Creates the process tap, the private aggregate device wrapping it, and the IO proc, then
  /// starts the aggregate device. On any failure, tears down only what this call created and
  /// rethrows; the listener, timer, and buffer (owned by the caller) are untouched.
  private func setUpCaptureGraph() throws {
    var ownPID = getpid()
    var translateAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var ownProcessObject = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &translateAddress,
      UInt32(MemoryLayout<pid_t>.size), &ownPID, &size, &ownProcessObject)
    guard status == noErr else {
      DebugLogger.logError("SYSTEM-AUDIO: TranslatePIDToProcessObject failed (\(status))")
      throw NSError(domain: "SystemAudioCapture", code: Int(status))
    }
    ownProcessObjectID = ownProcessObject

    let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [ownProcessObject])
    let uuid = UUID()
    tapDescription.uuid = uuid
    tapDescription.isPrivate = true
    tapDescription.muteBehavior = .unmuted
    tapDescription.name = "WhisperShortcut Meeting Tap"

    var newTapID = AudioObjectID(kAudioObjectUnknown)
    status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
    guard status == noErr else {
      DebugLogger.logError("SYSTEM-AUDIO: AudioHardwareCreateProcessTap failed (\(status))")
      throw NSError(domain: "SystemAudioCapture", code: Int(status))
    }
    processTapID = newTapID
    tapUUID = uuid

    var tapFormatAddress = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var readTapFormat = AudioStreamBasicDescription()
    var tapFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    status = AudioObjectGetPropertyData(
      newTapID, &tapFormatAddress, 0, nil, &tapFormatSize, &readTapFormat)
    guard status == noErr else {
      DebugLogger.logError("SYSTEM-AUDIO: read tap format failed (\(status))")
      teardownCaptureGraph()
      throw NSError(domain: "SystemAudioCapture", code: Int(status))
    }
    tapFormat = readTapFormat

    guard let outputDeviceID = OutputRoute.readDefaultOutputDevice() else {
      DebugLogger.logError("SYSTEM-AUDIO: no default output device")
      teardownCaptureGraph()
      throw NSError(domain: "SystemAudioCapture", code: Int(kAudioHardwareUnknownPropertyError))
    }
    guard let outputUID = OutputRoute.readDeviceUID(outputDeviceID) else {
      DebugLogger.logError("SYSTEM-AUDIO: read output device UID failed")
      teardownCaptureGraph()
      throw NSError(domain: "SystemAudioCapture", code: Int(kAudioHardwareUnknownPropertyError))
    }
    outputDeviceNameAtStart = OutputRoute.current()?.deviceName ?? ""

    let aggregateDictionary: [String: Any] = [
      kAudioAggregateDeviceNameKey: "WhisperShortcut Meeting Tap",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: outputUID]
      ],
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapDriftCompensationKey: true,
          kAudioSubTapUIDKey: uuid.uuidString,
        ]
      ],
    ]

    var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    status = AudioHardwareCreateAggregateDevice(
      aggregateDictionary as CFDictionary, &newAggregateDeviceID)
    guard status == noErr else {
      DebugLogger.logError("SYSTEM-AUDIO: AudioHardwareCreateAggregateDevice failed (\(status))")
      teardownCaptureGraph()
      throw NSError(domain: "SystemAudioCapture", code: Int(status))
    }
    aggregateDeviceID = newAggregateDeviceID

    // Deviation from the literal spec text, reported in the handover: the aggregate's input
    // stream is documented as "the clock (main sub) device's input channels, then the tap's",
    // but there is no Core Audio API that states this layout as a guarantee — it is inferred
    // from how `kAudioAggregateDeviceMainSubDeviceKey` + `kAudioAggregateDeviceTapListKey`
    // compose. `skipChannelCount` leading channels (0 on every Mac whose default output has no
    // input side, i.e. ordinary speakers) are skipped; the rest are averaged to mono.
    var usedFormat = readTapFormat
    var skipChannels = 0
    var inputFormatAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var aggregateASBD = AudioStreamBasicDescription()
    var aggregateFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let formatStatus = AudioObjectGetPropertyData(
      newAggregateDeviceID, &inputFormatAddress, 0, nil, &aggregateFormatSize, &aggregateASBD)
    if formatStatus == noErr {
      usedFormat = aggregateASBD
      skipChannels = Self.readInputChannelCount(outputDeviceID)
    }
    skipChannelCount = skipChannels

    let isFloat32 =
      usedFormat.mFormatID == kAudioFormatLinearPCM
      && (usedFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
      && usedFormat.mBitsPerChannel == 32
    if !isFloat32 {
      DebugLogger.logWarning(
        "SYSTEM-AUDIO: aggregate input format is not 32-bit float, dropping captured audio")
    }
    let isNonInterleaved = (usedFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let totalChannels = Int(usedFormat.mChannelsPerFrame)
    let sampleRate = usedFormat.mSampleRate
    let simulate = simulateDenied

    var newIOProcID: AudioDeviceIOProcID?
    let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, inInputTime, outOutputData, _ in
      Self.silence(outOutputData)
      guard let self, isFloat32 else { return }

      let (frameCount, consumed) = self.downmix(
        inputData: inInputData, isNonInterleaved: isNonInterleaved,
        skipChannels: skipChannels, totalChannels: totalChannels)
      guard consumed, frameCount > 0 else { return }

      if simulate {
        for i in 0..<frameCount { self.scratch[i] = 0 }
      }

      let nowHost = AudioGetCurrentHostTime()
      let now = Date()
      let stamp = inInputTime.pointee
      var wallClock = now
      if stamp.mFlags.contains(.hostTimeValid), stamp.mHostTime <= nowHost {
        let deltaNanos = AudioConvertHostTimeToNanos(nowHost - stamp.mHostTime)
        wallClock = now.addingTimeInterval(-(Double(deltaNanos) / 1e9))
      }

      self.scratch.withUnsafeBufferPointer { full in
        let slice = UnsafeBufferPointer(rebasing: full[0..<frameCount])
        self.buffer.append(slice, sampleRate: sampleRate, wallClock: wallClock)
      }
    }
    status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, newAggregateDeviceID, queue, ioBlock)
    guard status == noErr, let newIOProcID else {
      DebugLogger.logError("SYSTEM-AUDIO: AudioDeviceCreateIOProcIDWithBlock failed (\(status))")
      teardownCaptureGraph()
      throw NSError(domain: "SystemAudioCapture", code: Int(status))
    }
    ioProcID = newIOProcID

    // Apple's header notes `kAudioAggregateDeviceTapAutoStartKey` can make this call block
    // until another process is actually playing audio. Called synchronously anyway, on the
    // caller's (main) thread, per spec — not moved to a background queue.
    status = AudioDeviceStart(newAggregateDeviceID, newIOProcID)
    guard status == noErr else {
      DebugLogger.logError("SYSTEM-AUDIO: AudioDeviceStart failed (\(status))")
      teardownCaptureGraph()
      throw NSError(domain: "SystemAudioCapture", code: Int(status))
    }
  }

  /// Tears down the tap, aggregate device, and IO proc, each only if it was created. Does not
  /// touch the default-output listener, the timer, or `buffer`.
  private func teardownCaptureGraph() {
    if let ioProcID {
      AudioDeviceStop(aggregateDeviceID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
    }
    ioProcID = nil

    if aggregateDeviceID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    }
    aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

    if processTapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(processTapID)
    }
    processTapID = AudioObjectID(kAudioObjectUnknown)
    tapUUID = nil
  }

  // MARK: Default output device changes

  private func handleDefaultOutputDeviceChanged() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isRunning, !restartInProgress else { return }
    restartInProgress = true
    defer { restartInProgress = false }

    teardownCaptureGraph()

    do {
      try setUpCaptureGraph()
      onOutputRouteChange?(OutputRoute.current())
    } catch {
      // Already logged inside setUpCaptureGraph().
      isRunning = false
      timer?.invalidate()
      timer = nil
    }
  }

  // MARK: Permission heuristic tick

  private func handleTick() {
    dispatchPrecondition(condition: .onQueue(.main))
    let suspected = heuristic.tick(
      dt: 1, othersPlaying: Self.isAnyOtherProcessPlaying(except: ownProcessObjectID),
      hasSeenNonZero: buffer.hasSeenNonZero)
    guard suspected != permissionSuspected else { return }
    permissionSuspected = suspected
    DebugLogger.logWarning("SYSTEM-AUDIO: permission suspected = \(suspected)")
    onPermissionSuspectedChange?(suspected)
  }

  // MARK: Downmix (IO callback thread)

  /// Skips `skipChannels` leading channels, averages the rest to mono float into `scratch`.
  /// Returns the frame count written and whether anything was written at all. Real-time: no
  /// allocation, no logging.
  private func downmix(
    inputData: UnsafePointer<AudioBufferList>, isNonInterleaved: Bool, skipChannels: Int,
    totalChannels: Int
  ) -> (frameCount: Int, consumed: Bool) {
    let tapChannels = totalChannels - skipChannels
    guard tapChannels > 0 else { return (0, false) }
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

    if isNonInterleaved {
      guard buffers.count > skipChannels else { return (0, false) }
      let rawFrameCount = Int(buffers[skipChannels].mDataByteSize) / MemoryLayout<Float>.size
      let frameCount = min(rawFrameCount, scratch.count)
      guard frameCount > 0 else { return (0, false) }
      let lastChannel = min(skipChannels + tapChannels, buffers.count)
      scratch.withUnsafeMutableBufferPointer { out in
        for frame in 0..<frameCount {
          var sum: Float = 0
          var count = 0
          for channel in skipChannels..<lastChannel {
            guard let data = buffers[channel].mData else { continue }
            sum += data.assumingMemoryBound(to: Float.self)[frame]
            count += 1
          }
          out[frame] = count > 0 ? sum / Float(count) : 0
        }
      }
      return (frameCount, true)
    }

    guard buffers.count > 0, let data = buffers[0].mData, totalChannels > 0 else {
      return (0, false)
    }
    let bytesPerFrame = totalChannels * MemoryLayout<Float>.size
    let rawFrameCount = Int(buffers[0].mDataByteSize) / bytesPerFrame
    let frameCount = min(rawFrameCount, scratch.count)
    guard frameCount > 0 else { return (0, false) }
    let samples = data.assumingMemoryBound(to: Float.self)
    scratch.withUnsafeMutableBufferPointer { out in
      for frame in 0..<frameCount {
        var sum: Float = 0
        var count = 0
        for channel in skipChannels..<totalChannels {
          sum += samples[frame * totalChannels + channel]
          count += 1
        }
        out[frame] = count > 0 ? sum / Float(count) : 0
      }
    }
    return (frameCount, true)
  }

  private static func silence(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    for buffer in buffers {
      if let data = buffer.mData {
        memset(data, 0, Int(buffer.mDataByteSize))
      }
    }
  }

  // MARK: Static Core Audio helpers

  private static func readInputChannelCount(_ deviceID: AudioObjectID) -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0
    else {
      return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
      return 0
    }
    let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func isAnyOtherProcessPlaying(except ownProcessObjectID: AudioObjectID) -> Bool {
    guard let processes = readProcessObjectList() else { return false }
    for processID in processes where processID != ownProcessObjectID {
      if isProcessRunningOutput(processID) { return true }
    }
    return false
  }

  private static func readProcessObjectList() -> [AudioObjectID]? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        == noErr, size > 0
    else {
      return nil
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    var mutableSize = size
    let status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
      guard let base = buffer.baseAddress else { return kAudio_ParamError }
      return AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &mutableSize, base)
    }
    guard status == noErr else { return nil }
    return ids
  }

  private static func isProcessRunningOutput(_ processID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningOutput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(processID, &address) else { return false }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value)
    guard status == noErr else { return false }
    return value != 0
  }
}
