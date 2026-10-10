import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Captures the whole scrollable page of the window under a click: scroll to the
/// top, grab frames while scrolling down, stitch them into one tall PNG.
enum FullPageCapture {

  struct Result {
    let pngData: Data
    let frameCount: Int
    let scrolled: Bool
    let pixelHeight: Int
  }

  /// `shift` is the number of new rows the next frame appends below the previous one.
  struct Overlap {
    let header: Int
    let footer: Int
    let shift: Int
    /// False when no scroll offset matched and `shift` is the whole middle (a guess).
    var aligned = true
  }

  /// Rows of agreement required before a scroll offset is trusted.
  ///
  /// The design note says 32. The locked fixture is a 100-row viewport (10-row
  /// header, 5-row footer, 85-row middle) scrolled by 60, which shares only 25
  /// middle rows — that case must still resolve to shift 60, so the floor is 25.
  /// A shorter overlap appends the whole middle instead of guessing.
  private static let minimumOverlapRows = 25
  /// Share of overlapping rows that must match. Not near 1: fixed elements that stay on screen
  /// while the page scrolls (sticky widgets, banners) never match at the true offset. The best
  /// score wins, so blank rows matching at a wrong offset do not beat the real one.
  private static let minimumMatchScore = 0.75
  private static let maximumFrames = 40
  private static let maximumStitchedHeight = 30_000
  private static let scrollChunkPixels = 1_200
  private static let scrollToTopPixels = 5_000
  private static let scrollToTopAttempts = 15

  @MainActor
  static func capture(atCocoaPoint point: NSPoint) async -> Result? {
    let screens = NSScreen.screens
    guard let primary = screens.first else {
      DebugLogger.log("FULLPAGE: no screen")
      return nil
    }
    // Cocoa points are bottom-left; CG global coords are top-left of the primary display.
    let cgPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
    DebugLogger.log("FULLPAGE: click cocoa=\(point) cg=\(cgPoint)")

    guard let windowID = targetWindowID(at: cgPoint) else { return nil }

    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
      DebugLogger.log("FULLPAGE: SCShareableContent failed: \(error.localizedDescription)")
      return nil
    }
    guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
      DebugLogger.log("FULLPAGE: SCWindow \(windowID) not in shareable content")
      return nil
    }

    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
    let scale = CGFloat(filter.pointPixelScale)
    let pixelWidth = Int(scWindow.frame.width * scale)
    let pixelHeight = Int(scWindow.frame.height * scale)
    guard pixelWidth > 0, pixelHeight > 0 else {
      DebugLogger.log("FULLPAGE: window \(windowID) has zero pixel size")
      return nil
    }
    var config = SCStreamConfiguration()
    config.width = pixelWidth
    config.height = pixelHeight
    config.showsCursor = false
    config.capturesAudio = false
    DebugLogger.log(
      "FULLPAGE: capturing window \(windowID) \(pixelWidth)x\(pixelHeight) scale=\(scale)")

    if !AXIsProcessTrusted() {
      DebugLogger.log("FULLPAGE: accessibility not trusted; capturing one frame")
      guard let image = await captureFrame(filter: filter, config: config),
        let png = pngData(from: image)
      else { return nil }
      return Result(pngData: png, frameCount: 1, scrolled: false, pixelHeight: image.height)
    }

    let savedCursor = CGEvent(source: nil)?.location
    CGWarpMouseCursorPosition(cgPoint)
    defer {
      if let savedCursor {
        CGWarpMouseCursorPosition(savedCursor)
      }
    }

    guard let top = await scrollToTop(filter: filter, config: config, at: cgPoint) else {
      return nil
    }
    let stepPixels = max(1, Int(0.7 * scWindow.frame.height * scale))
    DebugLogger.log("FULLPAGE: scroll step \(stepPixels)px")
    let frames = await collectFrames(
      top: top, stepPixels: stepPixels, filter: filter, config: config, at: cgPoint)
    DebugLogger.log("FULLPAGE: frame count \(frames.count)")
    guard let stitched = stitch(frames), let png = pngData(from: stitched) else {
      DebugLogger.log("FULLPAGE: stitch or PNG encode failed")
      return nil
    }
    DebugLogger.log("FULLPAGE: final \(stitched.width)x\(stitched.height)")
    return Result(
      pngData: png, frameCount: frames.count, scrolled: true, pixelHeight: stitched.height)
  }

  /// FNV-1a 64 over every second pixel's RGB, left 3 % and right 10 % of the width skipped.
  /// Index 0 is the top row.
  ///
  /// The right edge holds the overlay scrollbar, whose thumb moves with every scroll and so
  /// changes nearly every row; floating widgets (chat bubbles, accessibility buttons) sit there
  /// too. Hashing the full width made real pages never align (Chrome, verivox.de, 2026-10-10).
  ///
  /// A bitmap `CGContext` keeps memory row 0 at the top when the image is drawn
  /// with the default transform (no flipped CTM). Verified: a `CGImage` whose
  /// first stored row is red lands in memory row 0; flipping the CTM puts that
  /// red row at the bottom instead.
  static func rowSignatures(_ image: CGImage) -> [UInt64] {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return [] }
    guard let ctx = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return [] }
    ctx.interpolationQuality = .none
    ctx.setShouldAntialias(false)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = ctx.data else { return [] }
    let bytesPerRow = ctx.bytesPerRow
    let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    var signatures = [UInt64]()
    signatures.reserveCapacity(height)
    for y in 0..<height {
      var hash: UInt64 = 14_695_981_039_346_656_037
      let row = pixels.advanced(by: y * bytesPerRow)
      var x = width * 3 / 100
      let xEnd = max(x + 1, width * 90 / 100)
      while x < xEnd {
        let pixel = row.advanced(by: x * 4)
        for offset in 0..<3 {
          hash ^= UInt64(pixel[offset])
          hash &*= 1_099_511_628_211
        }
        x += 2
      }
      signatures.append(hash)
    }
    return signatures
  }

  /// How `next` continues `previous` after a downward scroll.
  /// Nil means the two frames are the same image (no movement).
  static func findOverlap(previous a: [UInt64], next b: [UInt64]) -> Overlap? {
    let height = a.count
    guard height > 0, b.count == height else { return nil }

    var header = 0
    while header < height && a[header] == b[header] { header += 1 }

    var footer = 0
    while footer < height && a[height - 1 - footer] == b[height - 1 - footer] { footer += 1 }

    // Identical check uses the raw counts. Clamping each side to 45% first would
    // cap the sum at 90% of the height, and identical frames would never return nil.
    if header + footer >= height { return nil }

    let chromeCap = (height * 45) / 100
    if header > chromeCap { header = chromeCap }
    if footer > chromeCap { footer = chromeCap }

    let middleStart = header
    let middleCount = height - footer - header
    guard middleCount > 0 else {
      return Overlap(header: header, footer: footer, shift: 0)
    }

    var bestShift: Int?
    var bestScore = 0.0
    if middleCount > 1 {
      for d in 1..<middleCount {
        let overlapRows = middleCount - d
        if overlapRows < minimumOverlapRows { break }
        var matches = 0
        for i in 0..<overlapRows {
          if b[middleStart + i] == a[middleStart + i + d] { matches += 1 }
        }
        let score = Double(matches) / Double(overlapRows)
        if score >= minimumMatchScore && (bestShift == nil || score > bestScore) {
          bestScore = score
          bestShift = d
        }
      }
    }

    if let bestShift {
      DebugLogger.log(
        "FULLPAGE: overlap header=\(header) footer=\(footer) shift=\(bestShift) score=\(String(format: "%.3f", bestScore))"
      )
      return Overlap(header: header, footer: footer, shift: bestShift)
    }
    DebugLogger.log(
      "FULLPAGE: no overlap alignment (header=\(header) footer=\(footer)); appending whole middle (\(middleCount) rows)"
    )
    return Overlap(header: header, footer: footer, shift: middleCount, aligned: false)
  }

  /// Share of rows that are equal at the same index. Near 1 means the page did not move and only
  /// something animated (a carousel, a video, a blinking caret) changed.
  static func sameRowRatio(_ a: [UInt64], _ b: [UInt64]) -> Double {
    guard !a.isEmpty, a.count == b.count else { return 0 }
    let same = zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) }
    return Double(same) / Double(a.count)
  }

  /// Stacks frames top to bottom, dropping the overlap each scroll already showed.
  /// One frame is returned unchanged. Nil if the frames cannot be combined.
  static func stitch(_ frames: [CGImage]) -> CGImage? {
    guard let first = frames.first else { return nil }
    if frames.count == 1 { return first }
    let width = first.width
    let height = first.height
    guard width > 0, height > 0,
      frames.allSatisfy({ $0.width == width && $0.height == height })
    else {
      DebugLogger.log("FULLPAGE: stitch aborted, frame sizes differ")
      return nil
    }

    var overlaps: [Overlap] = []
    overlaps.reserveCapacity(frames.count - 1)
    for index in 1..<frames.count {
      let previous = rowSignatures(frames[index - 1])
      let next = rowSignatures(frames[index])
      guard let overlap = findOverlap(previous: previous, next: next) else {
        DebugLogger.log("FULLPAGE: stitch stopped, consecutive frames identical")
        return nil
      }
      overlaps.append(overlap)
    }

    let footer = overlaps[0].footer
    let shifts = overlaps.map(\.shift)
    let outputHeight = (height - footer) + shifts.reduce(0, +) + footer
    guard outputHeight > 0, let ctx = CGContext(
      data: nil,
      width: width,
      height: outputHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .none
    ctx.setShouldAntialias(false)

    var destTop = 0
    drawRows(first, from: 0, count: height - footer, into: ctx, destTop: &destTop, outputHeight: outputHeight)
    for (index, frame) in frames.enumerated().dropFirst() {
      let shift = shifts[index - 1]
      let cropTop = height - footer - shift
      drawRows(frame, from: cropTop, count: shift, into: ctx, destTop: &destTop, outputHeight: outputHeight)
    }
    if let last = frames.last, footer > 0 {
      drawRows(last, from: height - footer, count: footer, into: ctx, destTop: &destTop, outputHeight: outputHeight)
    }
    guard let image = ctx.makeImage() else { return nil }
    DebugLogger.log(
      "FULLPAGE: stitched \(frames.count) frames header=\(overlaps[0].header) footer=\(footer) shifts=\(shifts) size=\(width)x\(outputHeight)"
    )
    return image
  }

  // MARK: - Window and frames

  private static func targetWindowID(at cgPoint: CGPoint) -> CGWindowID? {
    guard let list = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else {
      DebugLogger.log("FULLPAGE: window list unavailable")
      return nil
    }
    let ourPID = Int(ProcessInfo.processInfo.processIdentifier)
    for entry in list {
      guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
      guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue != ourPID else { continue }
      guard (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0 else { continue }
      guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDict),
        bounds.contains(cgPoint)
      else { continue }
      guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
      let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
      DebugLogger.log("FULLPAGE: window id=\(number) owner=\(owner) bounds=\(bounds)")
      return number
    }
    DebugLogger.log("FULLPAGE: no window at \(cgPoint)")
    return nil
  }

  private static func captureFrame(filter: SCContentFilter, config: SCStreamConfiguration) async -> CGImage? {
    let image: CGImage? = await withCheckedContinuation { continuation in
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
        if let error = error {
          DebugLogger.log("FULLPAGE: captureImage error: \(error.localizedDescription)")
        }
        continuation.resume(returning: image)
      }
    }
    if image == nil {
      DebugLogger.log("FULLPAGE: capture returned no image")
    }
    return image
  }

  /// Positive `dy` scrolls content up (toward the top). Chunked so one event stays small.
  private static func postScroll(dy: Int, at point: CGPoint) async -> Bool {
    var remaining = dy
    while remaining != 0 {
      let chunk = min(scrollChunkPixels, max(-scrollChunkPixels, remaining))
      if let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: Int32(chunk),
        wheel2: 0,
        wheel3: 0
      ) {
        event.location = point
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
      }
      remaining -= chunk
      if remaining != 0 {
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return false }
      }
    }
    return true
  }

  private static func scrollToTop(
    filter: SCContentFilter, config: SCStreamConfiguration, at cgPoint: CGPoint
  ) async -> CGImage? {
    var latest: CGImage?
    var previous: [UInt64]?
    for attempt in 1...scrollToTopAttempts {
      if Task.isCancelled { return nil }
      guard await postScroll(dy: scrollToTopPixels, at: cgPoint) else { return nil }
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
      guard let frame = await captureFrame(filter: filter, config: config) else { return nil }
      let signature = rowSignatures(frame)
      if let previous, signature == previous {
        DebugLogger.log("FULLPAGE: top reached after \(attempt) scroll(s)")
        return frame
      }
      previous = signature
      latest = frame
    }
    DebugLogger.log("FULLPAGE: scroll-to-top stopped after \(scrollToTopAttempts) attempts")
    return latest
  }

  private static func collectFrames(
    top: CGImage,
    stepPixels: Int,
    filter: SCContentFilter,
    config: SCStreamConfiguration,
    at cgPoint: CGPoint
  ) async -> [CGImage] {
    var frames = [top]
    var lastSignature = rowSignatures(top)
    var stitchedHeight = top.height
    while frames.count < maximumFrames {
      if Task.isCancelled { break }
      guard await postScroll(dy: -stepPixels, at: cgPoint) else { break }
      do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
      guard let frame = await captureFrame(filter: filter, config: config) else { break }
      let signature = rowSignatures(frame)
      // Exact equality is not enough: an animation at the bottom of the page would otherwise
      // keep "moving" and the loop would append the same screen until the frame cap.
      if sameRowRatio(signature, lastSignature) >= 0.9 {
        DebugLogger.log("FULLPAGE: bottom reached at \(frames.count) frame(s)")
        break
      }
      guard let overlap = findOverlap(previous: lastSignature, next: signature) else { break }
      // No matching offset: stop with what we have rather than append a screen whose position
      // we only guessed (it would duplicate or skip content).
      guard overlap.aligned else {
        DebugLogger.log("FULLPAGE: no alignment at frame \(frames.count + 1); stopping")
        break
      }
      if stitchedHeight + overlap.shift > maximumStitchedHeight {
        DebugLogger.log(
          "FULLPAGE: height cap \(stitchedHeight)px, not adding shift \(overlap.shift)")
        break
      }
      stitchedHeight += overlap.shift
      frames.append(frame)
      lastSignature = signature
    }
    return frames
  }

  private static func pngData(from image: CGImage) -> Data? {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      DebugLogger.log("FULLPAGE: PNG encode failed")
      return nil
    }
    return data
  }

  /// `from` is a top-left row index. The context origin is bottom-left, so the
  /// crop is placed at `outputHeight - destTop - count`.
  private static func drawRows(
    _ image: CGImage,
    from top: Int,
    count: Int,
    into ctx: CGContext,
    destTop: inout Int,
    outputHeight: Int
  ) {
    guard count > 0, top >= 0, top + count <= image.height else { return }
    let cropRect = CGRect(x: 0, y: CGFloat(top), width: CGFloat(image.width), height: CGFloat(count))
    guard let crop = image.cropping(to: cropRect) else { return }
    let y = CGFloat(outputHeight - destTop - count)
    ctx.draw(crop, in: CGRect(x: 0, y: y, width: CGFloat(image.width), height: CGFloat(count)))
    destTop += count
  }
}
