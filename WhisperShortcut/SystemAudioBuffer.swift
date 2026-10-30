//
//  SystemAudioBuffer.swift
//  WhisperShortcut
//
//  A thread-safe ring of recently captured system audio, indexed by wall clock time so it can
//  be aligned with microphone audio captured on a different clock. Pure Swift: no Core Audio
//  here, so it can be driven from an IO callback on one thread and read from another (or from
//  tests) without touching the hardware.
//

import Foundation

final class SystemAudioBuffer {

  /// One contiguous run of samples at a single sample rate, starting at a wall-clock date.
  /// `startIndex` marks samples before it as logically dropped (too old to retain) without
  /// shifting the whole array on every real-time append; `compactIfNeeded` reclaims that prefix
  /// once it is large enough to be worth the copy.
  private struct Segment {
    var startDate: Date
    let sampleRate: Double
    var samples: [Float]
    var startIndex: Int = 0

    var validStartDate: Date {
      startDate.addingTimeInterval(Double(startIndex) / sampleRate)
    }

    var endDate: Date {
      startDate.addingTimeInterval(Double(samples.count) / sampleRate)
    }
  }

  /// Tolerance for small floating-point error when converting a time offset into a sample
  /// index, far below the spacing of a single sample at any realistic audio sample rate.
  private static let timeEpsilon: TimeInterval = 1e-6

  private let lock = NSLock()
  private var segments: [Segment] = []
  private var seenNonZero = false

  private let maxRetainedSeconds: TimeInterval

  init(maxRetainedSeconds: TimeInterval = 150) {
    self.maxRetainedSeconds = maxRetainedSeconds
  }

  /// True once any appended sample has had `abs(value) > 1e-6`. Never resets, including across
  /// `removeAll()` — it answers "has this capture ever carried real audio", not "is there audio
  /// right now".
  var hasSeenNonZero: Bool {
    lock.lock()
    defer { lock.unlock() }
    return seenNonZero
  }

  /// Number of distinct segments currently retained. Internal for tests: `extract()` cannot
  /// otherwise tell a single continuous run apart from two adjacent ones that happen to abut.
  var segmentCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return segments.count
  }

  /// Appends mono float samples whose first sample starts at `wallClock`. Real-time: amortised
  /// Array growth, no per-callback reallocation.
  func append(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, wallClock: Date) {
    guard samples.baseAddress != nil, samples.count > 0, sampleRate > 0 else { return }

    lock.lock()
    defer { lock.unlock() }

    if !seenNonZero {
      for value in samples where abs(value) > 1e-6 {
        seenNonZero = true
        break
      }
    }

    if !segments.isEmpty {
      let lastIndex = segments.count - 1
      let last = segments[lastIndex]
      if last.sampleRate == sampleRate, abs(wallClock.timeIntervalSince(last.endDate)) <= 0.05 {
        segments[lastIndex].samples.append(contentsOf: samples)
        trimIfNeeded()
        return
      }
    }

    var segment = Segment(startDate: wallClock, sampleRate: sampleRate, samples: [])
    segment.samples.reserveCapacity(samples.count)
    segment.samples.append(contentsOf: samples)
    segments.append(segment)
    trimIfNeeded()
  }

  /// Produces `Int(duration * outputRate)` samples resampled to `outputRate`. At an input rate
  /// of at least `outputRate`, each output sample is the average of the input samples inside
  /// its `[t, t + 1/outputRate)` window. Below `outputRate` that window can contain no sample
  /// (Bluetooth call mode is 16 kHz or 8 kHz into a 24 kHz meeting), so the sample is the linear
  /// interpolation of the input at `t` instead — or the single sample at `t` when the next one
  /// lies outside the slice. A time with no covering sample reads as 0; a time covered by two
  /// slices averages their contributions.
  func extract(from start: Date, duration: TimeInterval, outputRate: Double = 24_000) -> [Float] {
    let count = Int(duration * outputRate)
    guard count > 0 else { return [] }

    // Under the lock only copy the slices that can overlap the request; the averaging runs
    // after unlocking so the IO thread's append is never blocked for the whole resample.
    struct Slice {
      let startDate: Date
      let sampleRate: Double
      let firstIndex: Int
      let samples: [Float]
    }
    let dt = 1.0 / outputRate
    let end = start.addingTimeInterval(Double(count) * dt)

    lock.lock()
    var slices: [Slice] = []
    for segment in segments {
      // One sample of margin so a lower-rate slice can interpolate at the first and last
      // output time. The window average ignores samples that fall outside its own [t, t+dt).
      guard let range = sampleRange(in: segment, from: start, to: end, pad: 1) else { continue }
      slices.append(
        Slice(
          startDate: segment.startDate, sampleRate: segment.sampleRate,
          firstIndex: range.lowerBound, samples: Array(segment.samples[range])))
    }
    lock.unlock()

    var result = [Float](repeating: 0, count: count)
    guard !slices.isEmpty else { return result }

    for idx in 0..<count {
      let t = start.addingTimeInterval(Double(idx) * dt)
      let tEnd = t.addingTimeInterval(dt)

      var sum: Double = 0
      var n = 0
      for slice in slices {
        if slice.sampleRate < outputRate {
          let x = t.timeIntervalSince(slice.startDate) * slice.sampleRate
          let i0 = Int(floor(x))
          let frac = x - Double(i0)
          let lastIndex = slice.firstIndex + slice.samples.count - 1
          let i0Inside = i0 >= slice.firstIndex && i0 <= lastIndex
          let i1Inside = i0 + 1 >= slice.firstIndex && i0 + 1 <= lastIndex
          if i0Inside && i1Inside {
            let s0 = Double(slice.samples[i0 - slice.firstIndex])
            let s1 = Double(slice.samples[i0 + 1 - slice.firstIndex])
            sum += s0 * (1 - frac) + s1 * frac
            n += 1
          } else if i0Inside {
            sum += Double(slice.samples[i0 - slice.firstIndex])
            n += 1
          }
        } else {
          let loRaw = t.timeIntervalSince(slice.startDate) * slice.sampleRate
          let hiRaw = tEnd.timeIntervalSince(slice.startDate) * slice.sampleRate
          let lo = max(Int((loRaw - Self.timeEpsilon).rounded(.up)), slice.firstIndex)
          let hi = min(
            Int((hiRaw - Self.timeEpsilon).rounded(.up)) - 1,
            slice.firstIndex + slice.samples.count - 1)
          guard lo <= hi else { continue }
          for i in lo...hi {
            sum += Double(slice.samples[i - slice.firstIndex])
            n += 1
          }
        }
      }
      if n > 0 {
        result[idx] = Float(sum / Double(n))
      }
    }
    return result
  }

  /// `20*log10(rms)` of the samples whose time falls in `[now - window, now)`, floored at -160
  /// (silence, or no covering sample at all).
  func recentPowerDB(window: TimeInterval = 0.1, now: Date = Date()) -> Float {
    lock.lock()
    defer { lock.unlock() }

    let start = now.addingTimeInterval(-window)
    var sumSquares: Double = 0
    var n = 0
    for segment in segments {
      guard let range = sampleRange(in: segment, from: start, to: now) else { continue }
      for i in range {
        let value = Double(segment.samples[i])
        sumSquares += value * value
        n += 1
      }
    }
    guard n > 0 else { return -160 }
    let rms = (sumSquares / Double(n)).squareRoot()
    guard rms > 0 else { return -160 }
    return max(20 * log10(Float(rms)), -160)
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    segments.removeAll()
  }

  // MARK: - Private

  /// Half-open sample index range `[lo, hi)` within `segment` whose timestamps fall in
  /// `[from, to)`, or nil if the segment has no sample in that window. `pad` extends each end
  /// by that many samples so interpolation at the window edges still has a neighbour. Call
  /// with the lock held.
  private func sampleRange(in segment: Segment, from: Date, to: Date, pad: Int = 0) -> Range<Int>? {
    guard segment.endDate > from, segment.validStartDate < to else { return nil }

    let loRaw = from.timeIntervalSince(segment.startDate) * segment.sampleRate
    let hiRaw = to.timeIntervalSince(segment.startDate) * segment.sampleRate
    var lo = Int((loRaw - Self.timeEpsilon).rounded(.up))
    var hi = Int((hiRaw - Self.timeEpsilon).rounded(.up)) - 1

    lo = max(lo - pad, segment.startIndex)
    hi = min(hi + pad, segment.samples.count - 1)
    guard lo <= hi else { return nil }
    return lo..<(hi + 1)
  }

  /// Drops whole segments and leading samples older than `maxRetainedSeconds` before the end of
  /// the newest audio. Call with the lock held.
  private func trimIfNeeded() {
    guard let newest = segments.last else { return }
    let cutoff = newest.endDate.addingTimeInterval(-maxRetainedSeconds)

    var i = 0
    while i < segments.count {
      let segment = segments[i]
      if segment.endDate <= cutoff {
        segments.remove(at: i)
        continue
      }
      let rawIndex = cutoff.timeIntervalSince(segment.startDate) * segment.sampleRate
      let newStart = max(segment.startIndex, Int((rawIndex - Self.timeEpsilon).rounded(.up)))
      if newStart > segment.startIndex {
        segments[i].startIndex = min(newStart, segment.samples.count)
        compactIfNeeded(at: i)
      }
      i += 1
    }
  }

  /// Reclaims a dropped prefix once it is large enough to be worth the copy. Call with the
  /// lock held. Purely an allocation optimization: `sampleRange` already treats everything
  /// before `startIndex` as gone, so compacting earlier or later changes no observable result.
  private func compactIfNeeded(at index: Int) {
    let segment = segments[index]
    let dropped = segment.startIndex
    guard dropped > 0 else { return }
    // Only once at least half the array is stale, so the real-time append does not memmove the
    // whole retention window every second.
    guard dropped * 2 >= segment.samples.count else { return }
    segments[index].samples.removeFirst(dropped)
    segments[index].startDate = segment.startDate.addingTimeInterval(Double(dropped) / segment.sampleRate)
    segments[index].startIndex = 0
  }
}
