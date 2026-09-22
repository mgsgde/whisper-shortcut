import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The stall watchdog shared by the Gemini chat stream and Gemini TTS.
///
/// Budgets stay per caller — this only pins that an idle clock past the first-chunk budget
/// cancels and marks itself stalled, and that a clock which has already seen a chunk is judged
/// against the stall budget instead.
@Suite("Stream progress watchdog")
struct StreamProgressClockTests {

  final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() {
      lock.lock()
      value = true
      lock.unlock()
    }
    var isSet: Bool {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  @Test("Idle past the first-chunk budget cancels the stream and marks the clock stalled")
  func cancelsWhenFirstChunkBudgetElapses() async {
    let clock = StreamProgressClock()
    clock.touch(chunk: false)
    let flag = Flag()
    let task = clock.startWatchdog(
      pollInterval: 0.05,
      firstChunkTimeout: 0,
      stallTimeout: 60,
      logPrefix: "TEST-WATCHDOG",
      noun: "progress",
      firstLabel: "before first chunk",
      midLabel: "mid-stream",
      cancel: { flag.mark() })

    let deadline = Date().addingTimeInterval(2)
    while !flag.isSet, Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    task.cancel()
    #expect(flag.isSet)
    #expect(clock.isStalled)
  }

  @Test("After a chunk arrives, the stall budget applies, not the first-chunk budget")
  func stallBudgetAfterFirstChunk() async {
    let clock = StreamProgressClock()
    clock.touch(chunk: true)
    let flag = Flag()
    let task = clock.startWatchdog(
      pollInterval: 0.05,
      firstChunkTimeout: 0,
      stallTimeout: 60,
      logPrefix: "TEST-WATCHDOG",
      noun: "audio",
      firstLabel: "before first audio",
      midLabel: "mid-stream",
      cancel: { flag.mark() })

    try? await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    #expect(!flag.isSet)
    #expect(!clock.isStalled)
  }
}
