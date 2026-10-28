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

// MARK: - MeetingAudioMode

final class MeetingAudioModeTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
  }

  // The test host is the sandboxed Dev app and shares its defaults with everything else that
  // runs in it, so this is removed both via `defer` in each test and here.
  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
    super.tearDown()
  }

  func testUnsetDefaultsToInPerson() {
    defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode) }
    XCTAssertEqual(MeetingAudioMode.current, .inPerson)
  }

  func testSettingOnlinePersistsAndPostsNotification() {
    defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode) }
    let expectation = XCTNSNotificationExpectation(name: .liveMeetingAudioModeChanged)

    MeetingAudioMode.current = .online

    wait(for: [expectation], timeout: 1)
    XCTAssertEqual(MeetingAudioMode.current, .online)
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: UserDefaultsKeys.liveMeetingAudioMode), "online")
  }

  func testSettingTheSameValueAgainDoesNotPost() {
    defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode) }
    MeetingAudioMode.current = .online

    let expectation = XCTNSNotificationExpectation(name: .liveMeetingAudioModeChanged)
    expectation.isInverted = true

    MeetingAudioMode.current = .online

    wait(for: [expectation], timeout: 0.3)
  }

  func testUnknownStoredRawValueReadsAsInPerson() {
    defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode) }
    UserDefaults.standard.set("not-a-real-mode", forKey: UserDefaultsKeys.liveMeetingAudioMode)
    XCTAssertEqual(MeetingAudioMode.current, .inPerson)
  }
}

// MARK: - Recorder mixing + store wiring

final class MeetingSystemAudioMixTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.liveMeetingAudioMode)
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

  func testAudioModeChangeUpdatesStore() {
    MeetingAudioMode.current = .online
    let online = expectation(description: "store follows online")
    DispatchQueue.main.async { online.fulfill() }
    wait(for: [online], timeout: 1)
    XCTAssertEqual(LiveMeetingTranscriptStore.shared.audioMode, .online)

    MeetingAudioMode.current = .inPerson
    let inPerson = expectation(description: "store follows in person")
    DispatchQueue.main.async { inPerson.fulfill() }
    wait(for: [inPerson], timeout: 1)
    XCTAssertEqual(LiveMeetingTranscriptStore.shared.audioMode, .inPerson)
  }
}
