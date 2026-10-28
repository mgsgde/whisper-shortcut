import AVFoundation
import AudioToolbox
import CoreAudio
import XCTest

// Deviation from the spec text (reported in the handover): the spec says
// `@testable import WhisperShortcut`, but this test target's host is WhisperShortcut-AppStore
// and every existing test file in this target imports `WhisperShortcut_AppStore` — that is the
// module that actually exists here.
@testable import WhisperShortcut_AppStore

/// Shared fixed instant so every test below reasons about the same wall clock without depending
/// on `Date()` at run time.
private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

/// Appends `count` samples of a constant `value` at `sampleRate`, starting at `wallClock`.
private func appendConstant(
  _ buffer: SystemAudioBuffer, value: Float, count: Int, sampleRate: Double, at wallClock: Date
) {
  let samples = [Float](repeating: value, count: count)
  samples.withUnsafeBufferPointer { pointer in
    buffer.append(pointer, sampleRate: sampleRate, wallClock: wallClock)
  }
}

// MARK: - SystemAudioBuffer

final class SystemAudioBufferTests: XCTestCase {

  func testExtractOfExactlyCoveredRangeAveragesToInputValue() {
    let buffer = SystemAudioBuffer()
    appendConstant(buffer, value: 0.5, count: 48_000, sampleRate: 48_000, at: fixedDate)

    let extracted = buffer.extract(from: fixedDate, duration: 1)
    XCTAssertEqual(extracted.count, 24_000)
    for value in extracted {
      XCTAssertEqual(value, 0.5, accuracy: 0.001)
    }
  }

  func testExtractBeforeSegmentStartReadsZeroThenData() {
    let buffer = SystemAudioBuffer()
    appendConstant(buffer, value: 0.5, count: 48_000, sampleRate: 48_000, at: fixedDate)

    let extracted = buffer.extract(from: fixedDate.addingTimeInterval(-0.5), duration: 1)
    XCTAssertEqual(extracted.count, 24_000)
    for i in 0..<12_000 {
      XCTAssertEqual(extracted[i], 0, accuracy: 0.001, "index \(i)")
    }
    for i in 12_000..<24_000 {
      XCTAssertEqual(extracted[i], 0.5, accuracy: 0.001, "index \(i)")
    }
  }

  func testGapBetweenSegmentsKeepsThemSeparateAndReadsZero() {
    let buffer = SystemAudioBuffer()
    appendConstant(buffer, value: 0.5, count: 48_000, sampleRate: 48_000, at: fixedDate)
    appendConstant(
      buffer, value: 0.3, count: 48_000, sampleRate: 48_000, at: fixedDate.addingTimeInterval(3))

    XCTAssertEqual(buffer.segmentCount, 2)
    let gap = buffer.extract(from: fixedDate.addingTimeInterval(1), duration: 2)
    for value in gap {
      XCTAssertEqual(value, 0, accuracy: 0.001)
    }
  }

  func testContiguousAppendMergesIntoOneSegment() {
    let buffer = SystemAudioBuffer()
    appendConstant(buffer, value: 0.5, count: 48_000, sampleRate: 48_000, at: fixedDate)
    appendConstant(
      buffer, value: 0.5, count: 48_000, sampleRate: 48_000, at: fixedDate.addingTimeInterval(1))

    XCTAssertEqual(buffer.segmentCount, 1)
    let extracted = buffer.extract(from: fixedDate, duration: 2)
    XCTAssertEqual(extracted.count, 48_000)
    for value in extracted {
      XCTAssertEqual(value, 0.5, accuracy: 0.001)
    }
  }

  func testMaxRetainedSecondsDropsTheOldSegmentEntirely() {
    let buffer = SystemAudioBuffer(maxRetainedSeconds: 1)
    appendConstant(buffer, value: 0.5, count: 48_000, sampleRate: 48_000, at: fixedDate)
    appendConstant(
      buffer, value: 0.25, count: 48_000, sampleRate: 48_000, at: fixedDate.addingTimeInterval(3))

    let dropped = buffer.extract(from: fixedDate, duration: 1)
    for value in dropped {
      XCTAssertEqual(value, 0, accuracy: 0.001)
    }
    let retained = buffer.extract(from: fixedDate.addingTimeInterval(3), duration: 1)
    for value in retained {
      XCTAssertEqual(value, 0.25, accuracy: 0.001)
    }
  }

  func testHasSeenNonZeroThreshold() {
    let buffer = SystemAudioBuffer()
    appendConstant(buffer, value: 0, count: 100, sampleRate: 48_000, at: fixedDate)
    XCTAssertFalse(buffer.hasSeenNonZero)

    appendConstant(
      buffer, value: 1e-7, count: 100, sampleRate: 48_000,
      at: fixedDate.addingTimeInterval(100.0 / 48_000))
    XCTAssertFalse(buffer.hasSeenNonZero)

    appendConstant(
      buffer, value: 2e-6, count: 100, sampleRate: 48_000,
      at: fixedDate.addingTimeInterval(200.0 / 48_000))
    XCTAssertTrue(buffer.hasSeenNonZero)

    buffer.removeAll()
    XCTAssertTrue(buffer.hasSeenNonZero, "removeAll must not reset hasSeenNonZero")
  }

  func testRecentPowerDB() {
    let buffer = SystemAudioBuffer()
    let count = Int(0.1 * 48_000)
    appendConstant(buffer, value: 0.5, count: count, sampleRate: 48_000, at: fixedDate)
    let end = fixedDate.addingTimeInterval(Double(count) / 48_000)

    let db = buffer.recentPowerDB(window: 0.1, now: end)
    XCTAssertEqual(db, 20 * log10(Float(0.5)), accuracy: 0.1)

    let zeroBuffer = SystemAudioBuffer()
    appendConstant(zeroBuffer, value: 0, count: count, sampleRate: 48_000, at: fixedDate)
    let zeroDB = zeroBuffer.recentPowerDB(window: 0.1, now: end)
    XCTAssertEqual(zeroDB, -160, accuracy: 0.001)

    let emptyBuffer = SystemAudioBuffer()
    XCTAssertEqual(emptyBuffer.recentPowerDB(window: 0.1, now: fixedDate), -160, accuracy: 0.001)
  }
}

// MARK: - MeetingAudioMixer

final class MeetingAudioMixerTests: XCTestCase {

  func testMixPadsTruncatesAndClampsToUnitRange() {
    let mic: [Float] = [0.1, 0.2, 0.3, -0.9, 0.9]
    let shortSystem: [Float] = [0.05, 0.05]
    let mixedShort = MeetingAudioMixer.mix(mic: mic, system: shortSystem)
    XCTAssertEqual(mixedShort.count, mic.count)
    XCTAssertEqual(mixedShort[0], 0.15, accuracy: 0.0001)
    XCTAssertEqual(mixedShort[1], 0.25, accuracy: 0.0001)
    // Beyond the short system array: zero-padded, so the mic sample passes through unchanged.
    XCTAssertEqual(mixedShort[2], mic[2], accuracy: 0.0001)

    let longSystem: [Float] = [0, 0, 0, 0, 0, 10, 10, 10]
    let mixedLong = MeetingAudioMixer.mix(mic: mic, system: longSystem)
    XCTAssertEqual(mixedLong.count, mic.count)

    let clampedHigh = MeetingAudioMixer.mix(mic: [0.9], system: [0.5])
    XCTAssertEqual(clampedHigh[0], 1.0, accuracy: 0.0001)
    let clampedLow = MeetingAudioMixer.mix(mic: [-0.9], system: [-0.5])
    XCTAssertEqual(clampedLow[0], -1.0, accuracy: 0.0001)
  }

  func testMixInPlaceRewritesSameURLWithMixedSixteenBitAudio() throws {
    let sampleRate = 24_000.0
    let frameCount = 4_800
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mixInPlaceTest_\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    let writeSettings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    let writeFile = try AVAudioFile(
      forWriting: url, settings: writeSettings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
    guard
      let writeFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
      let writeBuffer = AVAudioPCMBuffer(
        pcmFormat: writeFormat, frameCapacity: AVAudioFrameCount(frameCount)),
      let writeChannelData = writeBuffer.floatChannelData
    else {
      XCTFail("could not allocate write buffer")
      return
    }
    writeBuffer.frameLength = AVAudioFrameCount(frameCount)
    for i in 0..<frameCount {
      writeChannelData[0][i] = 0.1
    }
    try writeFile.write(from: writeBuffer)
    writeFile.close()

    let system = [Float](repeating: 0.25, count: frameCount)
    try MeetingAudioMixer.mixInPlace(micURL: url, system: system)

    let readFile = try AVAudioFile(forReading: url)
    XCTAssertEqual(Int(readFile.length), frameCount)
    guard
      let readBuffer = AVAudioPCMBuffer(
        pcmFormat: readFile.processingFormat, frameCapacity: AVAudioFrameCount(readFile.length))
    else {
      XCTFail("could not allocate read buffer")
      return
    }
    try readFile.read(into: readBuffer)
    guard let readChannelData = readBuffer.floatChannelData else {
      XCTFail("no channel data after read")
      return
    }
    let tolerance = Float(1.0 / 32_768.0) * 2
    for i in 0..<frameCount {
      XCTAssertEqual(readChannelData[0][i], 0.35, accuracy: tolerance, "frame \(i)")
    }
  }

  func testPeakPowerDB() {
    XCTAssertEqual(MeetingAudioMixer.peakPowerDB([]), -160, accuracy: 0.001)
    XCTAssertEqual(MeetingAudioMixer.peakPowerDB([0, 0, 0]), -160, accuracy: 0.001)
    XCTAssertEqual(
      MeetingAudioMixer.peakPowerDB([0.1, -0.5, 0.3]), 20 * log10(Float(0.5)), accuracy: 0.1)
  }
}

// MARK: - OutputRoute

final class OutputRouteTests: XCTestCase {

  func testIsLikelySpeakerClassifiesKnownTransportsAndDataSources() {
    XCTAssertTrue(
      OutputRoute.isLikelySpeaker(
        transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6973_706b))
    XCTAssertFalse(
      OutputRoute.isLikelySpeaker(
        transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6864_706e))
    XCTAssertTrue(
      OutputRoute.isLikelySpeaker(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: nil))
    XCTAssertTrue(
      OutputRoute.isLikelySpeaker(transportType: kAudioDeviceTransportTypeHDMI, dataSource: nil))
    XCTAssertTrue(
      OutputRoute.isLikelySpeaker(
        transportType: kAudioDeviceTransportTypeDisplayPort, dataSource: nil))
    XCTAssertTrue(
      OutputRoute.isLikelySpeaker(transportType: kAudioDeviceTransportTypeAirPlay, dataSource: nil))
    XCTAssertFalse(
      OutputRoute.isLikelySpeaker(transportType: kAudioDeviceTransportTypeBluetooth, dataSource: nil))
    XCTAssertFalse(
      OutputRoute.isLikelySpeaker(
        transportType: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil))
    XCTAssertFalse(
      OutputRoute.isLikelySpeaker(transportType: kAudioDeviceTransportTypeUSB, dataSource: nil))
  }
}

// MARK: - SystemAudioPermissionHeuristic

final class SystemAudioPermissionHeuristicTests: XCTestCase {

  func testNotPlayingNeverSuspects() {
    var heuristic = SystemAudioPermissionHeuristic()
    for _ in 0..<5 {
      XCTAssertFalse(heuristic.tick(dt: 1, othersPlaying: false, hasSeenNonZero: false))
    }
  }

  func testSevenTicksFalseEighthTrue() {
    var heuristic = SystemAudioPermissionHeuristic()
    for _ in 0..<7 {
      XCTAssertFalse(heuristic.tick(dt: 1, othersPlaying: true, hasSeenNonZero: false))
    }
    XCTAssertTrue(heuristic.tick(dt: 1, othersPlaying: true, hasSeenNonZero: false))
  }

  func testAccumulatorIsCumulativeAcrossAPause() {
    var heuristic = SystemAudioPermissionHeuristic()
    for _ in 0..<4 {
      XCTAssertFalse(heuristic.tick(dt: 1, othersPlaying: true, hasSeenNonZero: false))
    }
    XCTAssertFalse(heuristic.tick(dt: 1, othersPlaying: false, hasSeenNonZero: false))
    for _ in 0..<3 {
      XCTAssertFalse(heuristic.tick(dt: 1, othersPlaying: true, hasSeenNonZero: false))
    }
    XCTAssertTrue(heuristic.tick(dt: 1, othersPlaying: true, hasSeenNonZero: false))
  }

  func testNeverSuspectsOnceRealAudioHasBeenSeen() {
    var heuristic = SystemAudioPermissionHeuristic()
    for _ in 0..<10 {
      XCTAssertFalse(heuristic.tick(dt: 1, othersPlaying: true, hasSeenNonZero: true))
    }
  }

  func testRealAudioAfterSuspectedClearsTheAccumulator() {
    var heuristic = SystemAudioPermissionHeuristic()
    for _ in 0..<7 {
      _ = heuristic.tick(dt: 1, othersPlaying: true, hasSeenNonZero: false)
    }
    XCTAssertTrue(heuristic.tick(dt: 1, othersPlaying: true, hasSeenNonZero: false))

    XCTAssertFalse(heuristic.tick(dt: 1, othersPlaying: true, hasSeenNonZero: true))
    XCTAssertEqual(heuristic.othersPlayingSeconds, 0)
  }
}

// MARK: - MeetingAudioRouting

final class MeetingAudioRoutingTests: XCTestCase {

  private func route(_ name: String, transport: UInt32, dataSource: UInt32?) -> OutputRoute {
    OutputRoute(deviceName: name, transportType: transport, dataSource: dataSource)
  }

  func testAutomaticBuiltInSpeakerIsMicrophoneOnly() {
    let routing = MeetingAudioRouting.resolve(
      preference: .automatic,
      route: route(
        "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn,
        dataSource: 0x6973_706b))
    XCTAssertEqual(routing, .speakers)
  }

  func testAutomaticBuiltInHeadphonesMixSystemAudio() {
    let routing = MeetingAudioRouting.resolve(
      preference: .automatic,
      route: route(
        "External Headphones", transport: kAudioDeviceTransportTypeBuiltIn,
        dataSource: 0x6864_706e))
    XCTAssertEqual(routing, .headphones)
  }

  func testAutomaticBluetoothMixesSystemAudio() {
    let routing = MeetingAudioRouting.resolve(
      preference: .automatic,
      route: route("AirPods", transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil))
    XCTAssertEqual(routing, .headphones)
  }

  func testAutomaticHDMIIsMicrophoneOnly() {
    let routing = MeetingAudioRouting.resolve(
      preference: .automatic,
      route: route("HDMI", transport: kAudioDeviceTransportTypeHDMI, dataSource: nil))
    XCTAssertEqual(routing, .speakers)
  }

  func testAutomaticNilRouteIsMicrophoneOnly() {
    XCTAssertEqual(
      MeetingAudioRouting.resolve(preference: .automatic, route: nil), .noOutputDevice)
  }

  func testAlwaysMixOnSpeakersStaysManualMix() {
    let routing = MeetingAudioRouting.resolve(
      preference: .alwaysMixSystemAudio,
      route: route(
        "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn,
        dataSource: 0x6973_706b))
    XCTAssertEqual(routing, .manualMix)
  }

  func testMicrophoneOnlyOnHeadphonesStaysManual() {
    let routing = MeetingAudioRouting.resolve(
      preference: .microphoneOnly,
      route: route(
        "External Headphones", transport: kAudioDeviceTransportTypeBuiltIn,
        dataSource: 0x6864_706e))
    XCTAssertEqual(routing, .manualMicrophoneOnly)
  }

  func testMixesSystemAudioAndIsManualForEveryCase() {
    XCTAssertTrue(MeetingAudioRouting.headphones.mixesSystemAudio)
    XCTAssertFalse(MeetingAudioRouting.headphones.isManual)

    XCTAssertFalse(MeetingAudioRouting.speakers.mixesSystemAudio)
    XCTAssertFalse(MeetingAudioRouting.speakers.isManual)

    XCTAssertFalse(MeetingAudioRouting.noOutputDevice.mixesSystemAudio)
    XCTAssertFalse(MeetingAudioRouting.noOutputDevice.isManual)

    XCTAssertTrue(MeetingAudioRouting.manualMix.mixesSystemAudio)
    XCTAssertTrue(MeetingAudioRouting.manualMix.isManual)

    XCTAssertFalse(MeetingAudioRouting.manualMicrophoneOnly.mixesSystemAudio)
    XCTAssertTrue(MeetingAudioRouting.manualMicrophoneOnly.isManual)
  }
}

// MARK: - MeetingAudioPreference

final class MeetingAudioPreferenceTests: XCTestCase {

  override func setUp() {
    super.setUp()
    clearAudioPreferenceDefaults()
  }

  // The test host is the sandboxed Dev app and shares its defaults with everything else that
  // runs in it, so both keys are removed here as well as around each test.
  override func tearDown() {
    clearAudioPreferenceDefaults()
    super.tearDown()
  }

  private func clearAudioPreferenceDefaults() {
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioPreference)
  }

  func testUnsetDefaultsToAutomatic() {
    XCTAssertEqual(MeetingAudioPreference.current, .automatic)
  }

  func testUnknownStoredRawValueReadsAsAutomatic() {
    UserDefaults.standard.set(
      "not-a-real-mode", forKey: UserDefaultsKeys.liveMeetingAudioPreference)
    XCTAssertEqual(MeetingAudioPreference.current, .automatic)
  }

  func testSettingPreferencePersistsAndPostsOnce() {
    var posts = 0
    let token = NotificationCenter.default.addObserver(
      forName: .liveMeetingAudioPreferenceChanged, object: nil, queue: nil
    ) { _ in
      posts += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    MeetingAudioPreference.current = .alwaysMixSystemAudio

    XCTAssertEqual(posts, 1)
    XCTAssertEqual(MeetingAudioPreference.current, .alwaysMixSystemAudio)
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: UserDefaultsKeys.liveMeetingAudioPreference),
      MeetingAudioPreference.alwaysMixSystemAudio.rawValue)
  }

  func testSettingTheSameValueAgainDoesNotPost() {
    MeetingAudioPreference.current = .microphoneOnly

    let expectation = XCTNSNotificationExpectation(name: .liveMeetingAudioPreferenceChanged)
    expectation.isInverted = true

    MeetingAudioPreference.current = .microphoneOnly

    wait(for: [expectation], timeout: 0.3)
  }
}

// MARK: - Legacy audio-mode migration

final class MeetingAudioMigrationTests: XCTestCase {

  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioPreference)
    suiteName = "MeetingAudioMigrationTests-\(UUID())"
    defaults = UserDefaults(suiteName: suiteName)
    XCTAssertNotNil(defaults)
  }

  override func tearDown() {
    defaults?.removePersistentDomain(forName: suiteName)
    defaults = nil
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioPreference)
    super.tearDown()
  }

  func testInPersonMigratesToAutomaticAndRemovesLegacyKey() {
    defaults.set("inPerson", forKey: UserDefaultsKeys.liveMeetingAudioMode)
    MeetingAudioPreference.migrateLegacyAudioMode(defaults)
    XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.liveMeetingAudioMode))
    XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.liveMeetingAudioPreference))
    XCTAssertEqual(MeetingAudioPreference.load(defaults), .automatic)
  }

  func testOnlineMigratesToAutomaticAndRemovesLegacyKey() {
    defaults.set("online", forKey: UserDefaultsKeys.liveMeetingAudioMode)
    MeetingAudioPreference.migrateLegacyAudioMode(defaults)
    XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.liveMeetingAudioMode))
    XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.liveMeetingAudioPreference))
    XCTAssertEqual(MeetingAudioPreference.load(defaults), .automatic)
  }

  func testUnsetMigrationIsANoOp() {
    MeetingAudioPreference.migrateLegacyAudioMode(defaults)
    XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.liveMeetingAudioMode))
    XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.liveMeetingAudioPreference))
    XCTAssertEqual(MeetingAudioPreference.load(defaults), .automatic)
  }

  func testMigrationTwiceIsHarmless() {
    defaults.set("online", forKey: UserDefaultsKeys.liveMeetingAudioMode)
    MeetingAudioPreference.migrateLegacyAudioMode(defaults)
    MeetingAudioPreference.migrateLegacyAudioMode(defaults)
    XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.liveMeetingAudioMode))
    XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.liveMeetingAudioPreference))
    XCTAssertEqual(MeetingAudioPreference.load(defaults), .automatic)
  }
}

// MARK: - Recorder mixing + store wiring

final class MeetingSystemAudioMixTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioPreference)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioPreference)
    super.tearDown()
  }

  func testMixSystemAudioIntoSilentChunkKeepsLengthAndAddsSignal() throws {
    let sampleRate = 24_000.0
    let frameCount = 48_000  // 2 s
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mixSystemAudioTest_\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    let writeFile = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
    let silence = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
    silence.frameLength = AVAudioFrameCount(frameCount)  // zero-filled
    try writeFile.write(from: silence)
    writeFile.close()

    let wallStart = Date()
    let buffer = SystemAudioBuffer()
    let systemRate = 48_000.0
    let sine = (0..<96_000).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / systemRate)) }
    sine.withUnsafeBufferPointer {
      buffer.append($0, sampleRate: systemRate, wallClock: wallStart)
    }

    try LiveMeetingRecorder.mixSystemAudio(into: url, buffer: buffer, wallStart: wallStart)

    let readFile = try AVAudioFile(forReading: url)
    XCTAssertEqual(Int(readFile.length), frameCount)
    let readFormat = readFile.processingFormat
    let readBuffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: AVAudioFrameCount(frameCount)))
    try readFile.read(into: readBuffer)
    let channel = try XCTUnwrap(readBuffer.floatChannelData)[0]
    var peak: Float = 0
    for i in 0..<Int(readBuffer.frameLength) { peak = max(peak, abs(channel[i])) }
    XCTAssertEqual(peak, 0.3, accuracy: 0.02)
  }

  func testAudioPreferenceChangeUpdatesStore() {
    MeetingAudioPreference.current = .alwaysMixSystemAudio
    let mix = expectation(description: "store follows always mix")
    DispatchQueue.main.async { mix.fulfill() }
    wait(for: [mix], timeout: 1)
    XCTAssertEqual(LiveMeetingTranscriptStore.shared.audioPreference, .alwaysMixSystemAudio)

    MeetingAudioPreference.current = .microphoneOnly
    let microphone = expectation(description: "store follows microphone only")
    DispatchQueue.main.async { microphone.fulfill() }
    wait(for: [microphone], timeout: 1)
    XCTAssertEqual(LiveMeetingTranscriptStore.shared.audioPreference, .microphoneOnly)
  }
}
