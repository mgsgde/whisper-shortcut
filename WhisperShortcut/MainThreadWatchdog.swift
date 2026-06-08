//
//  MainThreadWatchdog.swift
//  WhisperShortcut
//
//  Turns a silent main-thread freeze into a logged stack trace.
//
//  Hangs are the one failure mode normal logging can't capture: when the main thread
//  wedges (e.g. a non-converging SwiftUI layout/scroll-anchor loop in a long chat — see
//  the freezes investigated 2026-06), the runloop stops draining, so every DebugLogger
//  call from the UI also stops. The last log line is merely *where* it wedged; there is
//  no further signal. The only way to see *what* the main thread is stuck doing is to
//  sample it from the outside.
//
//  This watchdog does exactly that, automatically: a background queue pings the main
//  thread once per second; if the main thread fails to answer within `stallThreshold`,
//  it shells out to `/usr/bin/sample` against our own pid and writes the captured stack
//  to the Logs directory (hang-<timestamp>.txt) plus a summary line to the normal log.
//  When the main thread recovers, it logs how long the stall lasted. No user action and
//  no attached debugger required — the next freeze leaves evidence behind.
//

import Foundation
import AppKit

final class MainThreadWatchdog {
  static let shared = MainThreadWatchdog()

  /// How often the background queue pings the main thread.
  private let interval: TimeInterval = 1.0
  /// Consecutive missed pings (≈ seconds) before we treat the main thread as hung and sample it.
  private let stallTicks = 4

  /// Serial queue that owns all mutable state below — never touched from the main thread directly.
  private let queue = DispatchQueue(label: "com.magnusgoedde.whispershortcut.watchdog", qos: .utility)
  /// Pings dispatched to main that have not yet run. 0 = main is responsive.
  private var outstanding = 0
  /// True once we've captured a sample for the current stall, so we sample at most once per hang.
  private var didSampleThisStall = false
  /// Wall-clock when the current stall began (first missed ping), for the recovery duration log.
  private var stallStartedAt: Date?
  private var started = false

  private init() {}

  /// Starts the watchdog. Safe to call once, from `applicationDidFinishLaunching`.
  func start() {
    queue.async {
      guard !self.started else { return }
      self.started = true
      DebugLogger.logInfo("WATCHDOG: started (interval=\(self.interval)s, stallThreshold=\(self.stallTicks)s)")
      self.scheduleNextCheck()
    }
  }

  private func scheduleNextCheck() {
    queue.asyncAfter(deadline: .now() + interval) { [weak self] in
      guard let self else { return }
      self.outstanding += 1
      let missed = self.outstanding

      if missed >= self.stallTicks && !self.didSampleThisStall {
        self.didSampleThisStall = true
        if self.stallStartedAt == nil { self.stallStartedAt = Date() }
        let stalledSeconds = self.interval * Double(missed)
        DebugLogger.logError(
          "WATCHDOG: main thread unresponsive for ≥\(Int(stalledSeconds))s — capturing sample")
        self.captureSample()
      } else if missed == 1 {
        // First missed ping of a potential stall — remember when it began.
        self.stallStartedAt = Date()
      }

      // Ping the main thread. This block only runs once the main runloop drains, i.e. when
      // the main thread is responsive — so its execution is itself the "alive" signal.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.queue.async {
          if self.didSampleThisStall, let start = self.stallStartedAt {
            let recovered = Date().timeIntervalSince(start)
            DebugLogger.logWarning(
              "WATCHDOG: main thread recovered after \(String(format: "%.1f", recovered))s stall")
          }
          self.outstanding = 0
          self.didSampleThisStall = false
          self.stallStartedAt = nil
        }
      }

      self.scheduleNextCheck()
    }
  }

  /// Runs `sample` against our own process and writes the stack to the Logs directory.
  /// Called on `queue` (never the main thread), so the synchronous `Process` wait is safe.
  private func captureSample() {
    let pid = getpid()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())
    let outURL = AppSupportPaths.logsURL().appendingPathComponent("hang-\(stamp).txt")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    // sample <pid> <duration> -mayDie  — 2s is enough to characterize a pinned loop.
    process.arguments = [String(pid), "2", "-mayDie", "-file", outURL.path]
    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        DebugLogger.logError("WATCHDOG: hang sample written to \(outURL.lastPathComponent)")
      } else {
        DebugLogger.logError(
          "WATCHDOG: sample exited \(process.terminationStatus) (sandbox/permission?) — no stack captured")
      }
    } catch {
      DebugLogger.logError("WATCHDOG: failed to launch sample: \(error.localizedDescription)")
    }
  }
}
