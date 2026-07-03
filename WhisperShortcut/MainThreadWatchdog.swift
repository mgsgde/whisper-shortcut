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
//  sample it from another thread.
//
//  This watchdog does exactly that, automatically: a background queue pings the main
//  thread once per second; if the main thread fails to answer within `stallThreshold`,
//  it captures the main thread's stack *in-process* (Mach thread state + frame-pointer
//  walk, symbolicated with dladdr) and writes it to the Logs directory (hang-<timestamp>.txt)
//  plus a summary line to the normal log. When the main thread recovers, it logs how long
//  the stall lasted.
//
//  Why in-process instead of shelling out to /usr/bin/sample: under the App Sandbox the
//  app cannot spawn and attach `sample` to its own pid (it exits 255 — "no stack
//  captured"), so the previous approach produced no evidence for real users. Reading our
//  own thread state via Mach needs no extra entitlement and works inside the sandbox.
//

import Foundation
import AppKit
import Darwin

/// Thread-safe registry of cancellables the watchdog can abort when it detects a stall.
///
/// Kept deliberately separate from any `@MainActor` state (e.g. `ChatViewModel.sendTasks`) so the
/// watchdog's background queue can cancel without racing the main thread. `Task.cancel()` is safe
/// to call from any thread; only *reading* the collection needs the lock.
///
/// Purpose: defense-in-depth for the chat streaming freeze. The structural fix (streaming bubble
/// rendered outside the LazyVStack) should prevent the wedge, but if a slow-converging layout
/// transaction still stalls the main thread, cancelling the in-flight send stops the network stream
/// (no further token deltas pile onto the wedged bubble) and flags cancellation so that, on
/// recovery, `commitPartialOrRemove` commits the partial reply and detaches the streaming buffer —
/// ending the growth loop instead of letting it stream on for minutes (cf. hang-20260701-134623,
/// which "recovered" only after 46 min).
final class StallCancellationRegistry {
  static let shared = StallCancellationRegistry()

  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]

  func register(_ id: UUID, task: Task<Void, Never>) {
    lock.lock(); defer { lock.unlock() }
    tasks[id] = task
  }

  func unregister(_ id: UUID) {
    lock.lock(); defer { lock.unlock() }
    tasks[id] = nil
  }

  /// Cancels every registered task and clears the registry. Returns the count cancelled.
  @discardableResult
  func cancelAll() -> Int {
    lock.lock()
    let snapshot = tasks
    tasks.removeAll()
    lock.unlock()
    for task in snapshot.values { task.cancel() }
    return snapshot.count
  }
}

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
  /// Mach port for the main thread, captured once at startup. Used to read its stack while hung.
  private var mainThreadMachPort: thread_t = mach_port_t(MACH_PORT_NULL)
  /// Last activity breadcrumb, owned by `queue`. Written via `note(_:)` from any thread and folded
  /// into the hang header so a captured stack says *what* the app was doing when it wedged (e.g.
  /// "chat-send streaming"), not just where in SwiftUI it stalled. Set before risky main-thread
  /// work; reset to a resting value when it completes.
  private var breadcrumb = "launch"

  private init() {}

  /// Records what the app is about to do (or just finished). Cheap and thread-safe — the hang
  /// capture (on `queue`) reads the most recent value, which already landed because `queue` keeps
  /// draining even while the main thread is wedged. Keep messages short and stable.
  func note(_ activity: String) {
    queue.async { self.breadcrumb = activity }
  }

  /// Starts the watchdog. Safe to call once, from `applicationDidFinishLaunching`.
  func start() {
    // Grab the main thread's Mach port from the main thread itself so we can sample it later.
    DispatchQueue.main.async {
      let port = mach_thread_self()
      self.queue.async { self.mainThreadMachPort = port }
    }
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
          "WATCHDOG: main thread unresponsive for ≥\(Int(stalledSeconds))s (activity: \(self.breadcrumb)) — capturing sample")
        self.captureMainThreadStack()
        // Circuit breaker: a stall while a chat reply is streaming is the freeze this registry
        // exists for. Cancel the in-flight send so the network stream stops feeding the wedged
        // bubble and the partial reply is committed on recovery. Gated on the breadcrumb so we
        // never abort unrelated main-thread work that merely happened to stall.
        if self.breadcrumb.hasPrefix("chat-send streaming") {
          let cancelled = StallCancellationRegistry.shared.cancelAll()
          if cancelled > 0 {
            DebugLogger.logError("WATCHDOG: circuit breaker cancelled \(cancelled) in-flight chat send(s) during stall")
          }
        }
      } else if missed == 1 {
        // First missed ping of a potential stall — remember when it began.
        self.stallStartedAt = Date()
      }

      // Ping the main thread. This block only runs once the main runloop drains, i.e. when
      // the main thread is responsive — so its execution is itself the "alive" signal.
      //
      // Post it via CFRunLoop in *both* the common modes and the modal-panel mode rather than
      // `DispatchQueue.main.async` (which the runloop only services in the default mode). While an
      // NSAlert `runModal` is up, the main thread is genuinely alive — it's spinning a modal event
      // loop in `NSModalPanelRunLoopMode`, not wedged — but a default-mode ping never drains, so the
      // old code reported a benign modal dialog as a multi-minute "hang" (e.g. the Live Meeting
      // safeguard alert: hang-20260701-131332.txt, "recovered" after 403s). Draining in the modal
      // mode too lets the ping run during a modal loop, so a modal correctly reads as responsive.
      let ping: () -> Void = { [weak self] in
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
      let mainRunLoop = CFRunLoopGetMain()
      let modes = [CFRunLoopMode.commonModes.rawValue, "NSModalPanelRunLoopMode" as CFString] as CFArray
      CFRunLoopPerformBlock(mainRunLoop, modes, ping)
      CFRunLoopWakeUp(mainRunLoop)

      self.scheduleNextCheck()
    }
  }

  /// Captures the main thread's call stack in-process (no external `sample`, sandbox-safe) and
  /// writes it to the Logs directory. Called on `queue` (never the main thread).
  private func captureMainThreadStack() {
    let port = mainThreadMachPort
    guard port != mach_port_t(MACH_PORT_NULL) else {
      DebugLogger.logError("WATCHDOG: main thread port not captured yet — no stack")
      return
    }

    let frames = backtrace(of: port)
    guard !frames.isEmpty else {
      DebugLogger.logError("WATCHDOG: could not read main thread stack")
      return
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())
    let outURL = AppSupportPaths.logsURL().appendingPathComponent("hang-\(stamp).txt")

    let header = "WhisperShortcut main-thread hang — \(stamp)\nactivity: \(breadcrumb)\n\n"
    let body = frames.enumerated()
      .map { String(format: "%2d  %@", $0.offset, $0.element) }
      .joined(separator: "\n")
    let text = header + body + "\n"

    do {
      try text.write(to: outURL, atomically: true, encoding: .utf8)
      DebugLogger.logError("WATCHDOG: hang stack (\(frames.count) frames) written to \(outURL.lastPathComponent)")
    } catch {
      // Even if the file write fails, surface the top frames so the log still carries signal.
      DebugLogger.logError("WATCHDOG: hang stack (top frames): \(frames.prefix(8).joined(separator: " | "))")
    }
  }

  /// Suspends the given thread, reads its register state, walks the frame-pointer chain, and
  /// symbolicates each return address with `dladdr`. Returns symbolicated frame strings.
  private func backtrace(of thread: thread_t) -> [String] {
    guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
    defer { thread_resume(thread) }

    var pc: UInt = 0
    var fp: UInt = 0

    #if arch(arm64)
    var state = arm_thread_state64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
    let kr = withUnsafeMutablePointer(to: &state) {
      $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
        thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return [] }
    pc = UInt(state.__pc)
    fp = UInt(state.__fp)
    #elseif arch(x86_64)
    var state = x86_thread_state64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<UInt32>.size)
    let kr = withUnsafeMutablePointer(to: &state) {
      $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
        thread_get_state(thread, thread_state_flavor_t(x86_THREAD_STATE64), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return [] }
    pc = UInt(state.__rip)
    fp = UInt(state.__rbp)
    #else
    return []
    #endif

    var addresses: [UInt] = [pc]
    let wordSize = UInt(MemoryLayout<UInt>.size)
    var depth = 0
    // Standard frame-pointer chain: [fp] = caller's fp, [fp + word] = return address.
    while depth < 64, let savedFP = readWord(at: fp), let ret = readWord(at: fp + wordSize) {
      if ret == 0 { break }
      addresses.append(ret)
      if savedFP <= fp { break }  // stack grows downward; the next fp must be at a higher address
      fp = savedFP
      depth += 1
    }

    return addresses.map(symbolicate)
  }

  /// Safely reads one pointer-sized word from our own task via Mach, so an invalid frame pointer
  /// returns nil instead of crashing the watchdog with EXC_BAD_ACCESS.
  private func readWord(at address: UInt) -> UInt? {
    guard address != 0, address % UInt(MemoryLayout<UInt>.alignment) == 0 else { return nil }
    var value: UInt = 0
    var outSize: vm_size_t = 0
    let kr = withUnsafeMutablePointer(to: &value) { ptr -> kern_return_t in
      vm_read_overwrite(
        mach_task_self_,
        vm_address_t(address),
        vm_size_t(MemoryLayout<UInt>.size),
        vm_address_t(UInt(bitPattern: ptr)),
        &outSize)
    }
    guard kr == KERN_SUCCESS, outSize == vm_size_t(MemoryLayout<UInt>.size) else { return nil }
    return value
  }

  /// Turns a return address into "0x… image symbol + offset" via dladdr.
  private func symbolicate(_ address: UInt) -> String {
    var info = dl_info()
    if let raw = UnsafeRawPointer(bitPattern: address), dladdr(raw, &info) != 0 {
      let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
      let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
      let base = UInt(bitPattern: info.dli_saddr)
      let offset = base != 0 && address >= base ? address - base : 0
      return String(format: "0x%016lx %@ %@ + %lu", address, image, symbol, offset)
    }
    return String(format: "0x%016lx ???", address)
  }
}
