//
//  SystemAudioCapture.swift
//  WhisperShortcut
//
//  Captures the audio the Mac is playing (the other side of an online meeting) via a Core Audio
//  process tap, so it can be mixed into the meeting recording alongside the microphone. Meant
//  for headphones, where the microphone cannot hear the other side. Through speakers the
//  microphone already hears them, and mixing would record them twice — see
//  `OutputRoute.isLikelySpeaker`.
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

/// Watches the Mac's default output device and that device's output data source, independent of
/// the system-audio tap, so a meeting can follow headphones vs. speakers while no tap is running.
/// Main thread only. Route changes are debounced: Bluetooth flaps for a moment while it connects.
final class OutputRouteMonitor {

  var onChange: ((OutputRoute?) -> Void)?
  private(set) var route: OutputRoute?

  private var started = false
  private var refreshGeneration = 0
  private var debounceWork: DispatchWorkItem?
  private var defaultOutputListener: AudioObjectPropertyListenerBlock?
  private var dataSourceListener: AudioObjectPropertyListenerBlock?
  private var dataSourceDeviceID: AudioObjectID?

  private static let debounce: TimeInterval = 0.5

  deinit {
    debounceWork?.cancel()
    removeListeners()
  }

  /// Reads the route synchronously and starts listening. Does not call `onChange`.
  func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !started else { return }
    started = true
    route = OutputRoute.current()
    addDefaultOutputListener()
    moveDataSourceListener(to: OutputRoute.readDefaultOutputDevice())
  }

  /// Idempotent. Drops listeners and any pending debounced read.
  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard started else { return }
    started = false
    refreshGeneration += 1
    debounceWork?.cancel()
    debounceWork = nil
    removeListeners()
  }

  // MARK: Listeners

  private func addDefaultOutputListener() {
    var address = Self.defaultOutputAddress()
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.handleDefaultOutputDeviceChanged()
    }
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    guard status == noErr else {
      DebugLogger.logError("OUTPUT-ROUTE: default output listener failed (\(status))")
      return
    }
    defaultOutputListener = block
  }

  /// Plugging headphones into the built-in jack can change only the data source, not the device.
  private func moveDataSourceListener(to deviceID: AudioObjectID?) {
    removeDataSourceListener()
    guard let deviceID, deviceID != kAudioObjectUnknown else { return }
    var address = Self.dataSourceAddress()
    guard AudioObjectHasProperty(deviceID, &address) else { return }
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.scheduleRouteRefresh()
    }
    let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
    guard status == noErr else {
      DebugLogger.logError("OUTPUT-ROUTE: data source listener failed (\(status))")
      return
    }
    dataSourceListener = block
    dataSourceDeviceID = deviceID
  }

  private func handleDefaultOutputDeviceChanged() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard started else { return }
    moveDataSourceListener(to: OutputRoute.readDefaultOutputDevice())
    scheduleRouteRefresh()
  }

  private func scheduleRouteRefresh() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard started else { return }
    refreshGeneration += 1
    let generation = refreshGeneration
    debounceWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.started, generation == self.refreshGeneration else { return }
      self.publishRouteIfChanged()
    }
    debounceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
  }

  private func publishRouteIfChanged() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard started else { return }
    let next = OutputRoute.current()
    guard next != route else { return }
    route = next
    logRoute(next)
    onChange?(next)
  }

  private func logRoute(_ route: OutputRoute?) {
    if let route {
      let transport = Self.transportLabel(route.transportType)
      DebugLogger.logAudio(
        "OUTPUT-ROUTE: \(route.deviceName) transport=\(transport) speaker=\(route.isLikelySpeaker)")
    } else {
      DebugLogger.logAudio("OUTPUT-ROUTE: (none) transport=0 speaker=false")
    }
  }

  /// A transport type is a FourCharCode when every byte is printable ASCII (some are space-padded,
  /// e.g. 'usb '); otherwise it is logged as a decimal so an unknown value is still visible.
  private static func transportLabel(_ value: UInt32) -> String {
    let bytes = [
      UInt8((value >> 24) & 0xFF),
      UInt8((value >> 16) & 0xFF),
      UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ]
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    guard printable, let text = String(bytes: bytes, encoding: .ascii) else {
      return String(value)
    }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? String(value) : trimmed
  }

  private func removeListeners() {
    if let block = defaultOutputListener {
      var address = Self.defaultOutputAddress()
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
      defaultOutputListener = nil
    }
    removeDataSourceListener()
  }

  private func removeDataSourceListener() {
    if let deviceID = dataSourceDeviceID, let block = dataSourceListener {
      var address = Self.dataSourceAddress()
      AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
    }
    dataSourceDeviceID = nil
    dataSourceListener = nil
  }

  private static func defaultOutputAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private static func dataSourceAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDataSource,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
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
  /// Main thread. Fired when the tap could not be started or restarted; the capture has already
  /// stopped itself.
  var onStartFailed: ((Error) -> Void)?
  private(set) var isRunning = false

  private let queue = DispatchQueue(
    label: "com.magnusgoedde.whispershortcut.meeting-system-audio", qos: .userInteractive)

  /// Serial queue that owns every Core Audio graph call (tap, aggregate device, IO proc start and
  /// stop). `AudioDeviceStart` can block for a minute or more behind the macOS "System Audio
  /// Recording" prompt, so none of it may ever run on the main thread.
  private let controlQueue = DispatchQueue(
    label: "com.magnusgoedde.whispershortcut.meeting-system-audio.control", qos: .userInitiated)

  // Owned by `controlQueue`.
  private var ownProcessObjectID = AudioObjectID(kAudioObjectUnknown)
  private var processTapID = AudioObjectID(kAudioObjectUnknown)
  private var tapUUID: UUID?
  private var tapFormat = AudioStreamBasicDescription()
  private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var skipChannelCount = 0
  /// The output device's nominal sample rate and input channel count as setUpCaptureGraph saw
  /// them. Written on `controlQueue`, read on main, so guarded by a lock. A format notification
  /// that matches these is an echo of our own aggregate device, not a real change.
  private let builtFormatLock = NSLock()
  private var builtFormat: (sampleRate: Double, inputChannels: Int)?
  private var outputDeviceNameAtStart = ""
  private var scratch: [Float] = []

  // Main thread only.
  private var ownProcessObjectIDMain = AudioObjectID(kAudioObjectUnknown)
  /// True once the graph is up; the permission heuristic must not run while the tap is still
  /// waiting on the permission prompt.
  private var tapActive = false
  /// Bumped by every start() and stop(); a late result from an older generation is ignored (the
  /// stop() that superseded it already queued its own teardown behind it).
  private var generation = 0
  private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
  private var restartInProgress = false
  /// A format change arrived while a restart was running; run one more when it completes.
  private var restartPending = false
  /// Listeners on the current default output device (sample rate, input channel count): when
  /// Bluetooth switches between call mode and A2DP the device stays the same but the tap's format
  /// does not.
  private var formatListenerDeviceID: AudioObjectID?
  private var formatListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var formatDebounceWork: DispatchWorkItem?
  private var formatGeneration = 0
  private static let formatDebounce: TimeInterval = 0.5
  private var timer: Timer?
  private var heuristic = SystemAudioPermissionHeuristic()
  private var permissionSuspected = false
  private var simulateDenied = false

  deinit {
    // Never blocks: the teardown runs on the control queue with copies of the IDs.
    let ioProc = ioProcID
    let aggregate = aggregateDeviceID
    let tap = processTapID
    if ioProc != nil || aggregate != kAudioObjectUnknown || tap != kAudioObjectUnknown {
      controlQueue.async {
        Self.destroyGraph(ioProcID: ioProc, aggregateDeviceID: aggregate, processTapID: tap)
      }
    }
    if let block = defaultOutputListenerBlock {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }
    if let deviceID = formatListenerDeviceID {
      for (var address, block) in formatListeners {
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
      }
    }
  }

  // MARK: Start / stop

  /// Returns immediately. The graph is built on `controlQueue`; failure arrives via
  /// `onStartFailed` (main thread).
  func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !isRunning else { return }

    #if DEBUG
      simulateDenied = ProcessInfo.processInfo.environment["WS_SIMULATE_SYSTEM_AUDIO_DENIED"] == "1"
    #endif

    isRunning = true
    tapActive = false
    generation += 1
    let gen = generation
    heuristic = SystemAudioPermissionHeuristic()
    permissionSuspected = false

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
      let error = NSError(domain: "SystemAudioCapture", code: Int(listenerStatus))
      stop()
      DispatchQueue.main.async { [weak self] in self?.onStartFailed?(error) }
      return
    }
    defaultOutputListenerBlock = listenerBlock
    moveFormatListeners(to: OutputRoute.readDefaultOutputDevice())

    let newTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.handleTick()
    }
    RunLoop.main.add(newTimer, forMode: .common)
    timer = newTimer

    let startedAt = Date()
    controlQueue.async { [weak self] in
      guard let self else { return }
      do {
        try self.setUpCaptureGraph()
        let ownObject = self.ownProcessObjectID
        let note = self.skipChannelCount > 0 ? ", skipped \(self.skipChannelCount) leading ch" : ""
        let summary =
          "\(Int(self.tapFormat.mSampleRate)) Hz, \(Int(self.tapFormat.mChannelsPerFrame)) ch, "
          + "output \(self.outputDeviceNameAtStart)\(note)"
        DispatchQueue.main.async {
          guard gen == self.generation, self.isRunning else {
            DebugLogger.logAudio("SYSTEM-AUDIO: start finished after stop, ignored")
            return
          }
          self.ownProcessObjectIDMain = ownObject
          self.tapActive = true
          let elapsed = String(format: "%.2f", Date().timeIntervalSince(startedAt))
          DebugLogger.logAudio("SYSTEM-AUDIO: started tap \(summary) after \(elapsed)s")
          self.onOutputRouteChange?(OutputRoute.current())
        }
      } catch {
        // Already logged inside setUpCaptureGraph().
        DispatchQueue.main.async {
          self.failIfCurrent(generation: gen, error: error)
        }
      }
    }
  }

  /// Main thread. Tears everything down and reports the failure, unless a stop()/start() has
  /// superseded `generation`.
  private func failIfCurrent(generation gen: Int, error: Error) {
    guard gen == generation, isRunning else { return }
    stop()
    onStartFailed?(error)
  }

  /// Idempotent; never clears `buffer` (the transcript pipeline still needs what was already
  /// captured once recording stops). Never blocks: the teardown is queued on `controlQueue`,
  /// behind a start that may still be waiting inside `AudioDeviceStart`.
  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    let wasRunning = isRunning
    isRunning = false
    tapActive = false
    generation += 1

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
    removeFormatListeners()
    formatGeneration += 1
    formatDebounceWork?.cancel()
    formatDebounceWork = nil
    restartPending = false

    controlQueue.async { [weak self] in
      self?.teardownCaptureGraph()
    }

    if wasRunning {
      DebugLogger.logAudio("SYSTEM-AUDIO: stopped")
    }
  }

  // MARK: Capture graph

  /// Creates the process tap, the private aggregate device wrapping it, and the IO proc, then
  /// starts the aggregate device. On any failure, tears down only what this call created and
  /// rethrows; the listener, timer, and buffer (owned by the caller) are untouched.
  private func setUpCaptureGraph() throws {
    dispatchPrecondition(condition: .onQueue(controlQueue))
    if scratch.isEmpty { scratch = [Float](repeating: 0, count: 32_768) }
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
    builtFormatLock.lock()
    builtFormat = (Self.readNominalSampleRate(outputDeviceID), Self.readInputChannelCount(outputDeviceID))
    builtFormatLock.unlock()

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

    // Blocks while macOS shows the "System Audio Recording" prompt (measured 90 s), and Apple's
    // header notes `kAudioAggregateDeviceTapAutoStartKey` can block it further. Runs on
    // `controlQueue`, never on the main thread.
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
    dispatchPrecondition(condition: .onQueue(controlQueue))
    Self.destroyGraph(
      ioProcID: ioProcID, aggregateDeviceID: aggregateDeviceID, processTapID: processTapID)
    ioProcID = nil
    aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    processTapID = AudioObjectID(kAudioObjectUnknown)
    tapUUID = nil
  }

  private static func destroyGraph(
    ioProcID: AudioDeviceIOProcID?, aggregateDeviceID: AudioObjectID, processTapID: AudioObjectID
  ) {
    if let ioProcID {
      AudioDeviceStop(aggregateDeviceID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
    }
    if aggregateDeviceID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    }
    if processTapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(processTapID)
    }
  }

  // MARK: Default output device changes

  private static func formatAddresses() -> [AudioObjectPropertyAddress] {
    [
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain),
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain),
    ]
  }

  /// Listens for sample-rate and input-channel changes on `deviceID` (the current default output).
  private func moveFormatListeners(to deviceID: AudioObjectID?) {
    dispatchPrecondition(condition: .onQueue(.main))
    removeFormatListeners()
    guard isRunning, let deviceID, deviceID != kAudioObjectUnknown else { return }
    for var address in Self.formatAddresses() {
      guard AudioObjectHasProperty(deviceID, &address) else { continue }
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.scheduleFormatRestart()
      }
      let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
      guard status == noErr else {
        DebugLogger.logError("SYSTEM-AUDIO: format listener failed (\(status))")
        continue
      }
      formatListeners.append((address, block))
    }
    formatListenerDeviceID = deviceID
  }

  private func removeFormatListeners() {
    if let deviceID = formatListenerDeviceID {
      for (var address, block) in formatListeners {
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
      }
    }
    formatListeners = []
    formatListenerDeviceID = nil
  }

  /// Bluetooth flaps, so a burst of format changes becomes one rebuild.
  private func scheduleFormatRestart() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isRunning else { return }
    formatGeneration += 1
    let generation = formatGeneration
    formatDebounceWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.isRunning, generation == self.formatGeneration else { return }
      // Building the aggregate device can itself fire these notifications; only a real
      // difference from what the graph was built with justifies a rebuild.
      self.builtFormatLock.lock()
      let built = self.builtFormat
      self.builtFormatLock.unlock()
      if let built, let device = OutputRoute.readDefaultOutputDevice(),
        Self.readNominalSampleRate(device) == built.sampleRate,
        Self.readInputChannelCount(device) == built.inputChannels
      {
        return
      }
      DebugLogger.log("SYSTEM-AUDIO: output format changed, rebuilding tap")
      self.handleDefaultOutputDeviceChanged()
    }
    formatDebounceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.formatDebounce, execute: work)
  }

  private func handleDefaultOutputDeviceChanged() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isRunning else { return }
    // The listeners follow the device the tap is about to be built for.
    moveFormatListeners(to: OutputRoute.readDefaultOutputDevice())
    guard !restartInProgress else {
      restartPending = true
      return
    }
    restartInProgress = true
    tapActive = false
    let gen = generation

    controlQueue.async { [weak self] in
      guard let self else { return }
      self.teardownCaptureGraph()
      do {
        try self.setUpCaptureGraph()
        let ownObject = self.ownProcessObjectID
        DispatchQueue.main.async {
          self.restartInProgress = false
          guard gen == self.generation, self.isRunning else { return }
          self.ownProcessObjectIDMain = ownObject
          self.tapActive = true
          self.onOutputRouteChange?(OutputRoute.current())
          if self.restartPending {
            self.restartPending = false
            self.handleDefaultOutputDeviceChanged()
          }
        }
      } catch {
        // Already logged inside setUpCaptureGraph().
        DispatchQueue.main.async {
          self.restartInProgress = false
          self.restartPending = false
          self.failIfCurrent(generation: gen, error: error)
        }
      }
    }
  }

  // MARK: Permission heuristic tick

  private func handleTick() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard tapActive else { return }
    let suspected = heuristic.tick(
      dt: 1, othersPlaying: Self.isAnyOtherProcessPlaying(except: ownProcessObjectIDMain),
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

  private static func readNominalSampleRate(_ deviceID: AudioObjectID) -> Double {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    return status == noErr ? value : 0
  }

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
