import Cocoa
import ScreenCaptureKit

class ChatWindowManager {
  static let shared = ChatWindowManager()
  private var windowController: ChatWindowController?

  private var cachedShareableContent: SCShareableContent?
  private var cachedShareableContentDate: Date?
  private let shareableContentCacheDuration: TimeInterval = 30

  private init() {}

  func toggle() {
    if isWindowOpen() {
      close()
    } else {
      show()
    }
  }

  func show(suppressFocusLossClose: Bool = false) {
    if windowController == nil {
      windowController = ChatWindowController()
    }
    if suppressFocusLossClose {
      windowController?.suppressCloseOnFocusLoss()
    }
    windowController?.showWindow()
    prefetchShareableContent()
    // Second firing point for an armed review prompt (besides menuWillOpen): shortcut-only
    // users may never open the status-item menu, but opening chat means they're focused on
    // this app, so prompting here can't steal focus from another app.
    Task { @MainActor in
      if UsageStatisticsNotice.shared.showIfDue() { return }
      ReviewPrompter.shared.showPendingPromptIfNeeded()
    }
  }

  /// Shows the chat window and switches to the Meeting view (for live meeting).
  func showAndSwitchToMeeting() {
    show()
    NotificationCenter.default.post(name: .chatSwitchToMeeting, object: nil)
  }

  func close() {
    windowController?.window?.close()
  }

  func isWindowOpen() -> Bool {
    guard let window = windowController?.window else { return false }
    return window.isVisible
  }

  /// Creates the window controller in the background so the first show() call is instant.
  func preWarm() {
    if windowController == nil {
      windowController = ChatWindowController()
    }
  }

  /// Pre-fetches SCShareableContent in the background to warm the cache before the user takes a screenshot.
  ///
  /// Only runs when Screen Recording is ALREADY granted. `SCShareableContent` triggers the macOS
  /// Screen Recording consent prompt on first use, so warming the cache on chat-window open would
  /// pop that prompt before the user ever asks for a screenshot. The preflight check
  /// (`CGPreflightScreenCaptureAccess`) does not prompt; the real prompt is deferred to the moment
  /// the user actually captures a screenshot.
  func prefetchShareableContent() {
    guard PermissionStatusChecker.status(for: .screenRecording) == .granted else {
      DebugLogger.log("GEMINI-SCREENSHOT: skip prefetch — Screen Recording not granted yet (prompt deferred to first capture)")
      return
    }
    Task { @MainActor in
      guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
      cachedShareableContent = content
      cachedShareableContentDate = Date()
      DebugLogger.log("GEMINI-SCREENSHOT: SCShareableContent pre-fetched and cached")
    }
  }

  /// Captures the display the user is working on for Dictate Prompt — no chat window required. That is
  /// the display holding the frontmost app's window, else the one under the mouse, else the main one.
  /// Returns JPEG data (max 1920 px wide, 80 % quality) or nil on failure (missing permission, no display, etc.).
  @MainActor
  func captureScreenForPromptMode() async -> Data? {
    if FocusedFieldSnapshot.isExcluded(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
      return nil
    }
    var content: SCShareableContent
    let now = Date()
    var fromCache = false
    if let cached = cachedShareableContent,
       let ts = cachedShareableContentDate,
       now.timeIntervalSince(ts) < shareableContentCacheDuration {
      content = cached
      fromCache = true
    } else {
      do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedShareableContent = content
        cachedShareableContentDate = now
      } catch {
        return nil
      }
    }

    let targetID = ScreenshotDisplayPicker.currentTargetDisplayID()
    // The cache may predate a display being plugged in or woken; refetch once if it lacks the target.
    if fromCache, let targetID, !content.displays.contains(where: { $0.displayID == targetID }),
       let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
      content = fresh
      cachedShareableContent = fresh
      cachedShareableContentDate = Date()
    }

    guard !content.displays.isEmpty else {
      return nil
    }

    let display = content.displays.first { $0.displayID == targetID } ?? content.displays[0]
    let ourApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
    let filter = SCContentFilter(display: display, excludingApplications: ourApp.map { [$0] } ?? [], exceptingWindows: [])

    var config = SCStreamConfiguration()
    config.capturesAudio = false
    config.width = Int(filter.contentRect.width) * Int(filter.pointPixelScale)
    config.height = Int(filter.contentRect.height) * Int(filter.pointPixelScale)

    let cgImage: CGImage? = await withCheckedContinuation { continuation in
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
        continuation.resume(returning: image)
      }
    }

    guard let cgImage else {
      return nil
    }

    // Resize to max 1920 px wide to keep the Gemini payload small
    let maxWidth = 1920
    let finalImage: CGImage
    if cgImage.width > maxWidth {
      let scale = CGFloat(maxWidth) / CGFloat(cgImage.width)
      let newWidth = maxWidth
      let newHeight = Int(CGFloat(cgImage.height) * scale)
      let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
      if let ctx = CGContext(
        data: nil, width: newWidth, height: newHeight,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) {
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        finalImage = ctx.makeImage() ?? cgImage
      } else {
        finalImage = cgImage
      }
    } else {
      finalImage = cgImage
    }

    let rep = NSBitmapImageRep(cgImage: finalImage)
    guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
      return nil
    }

    return jpegData
  }

  /// Captures the frontmost app's topmost normal window for Dictate Prompt. JPEG, at most 1400 px
  /// on the longer side, quality 0.75. Nil on any failure, including when WhisperShortcut itself
  /// is frontmost — the caller decides whether a full-display capture may stand in.
  @MainActor
  func captureFrontWindowForPromptMode() async -> Data? {
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    if frontmost == Bundle.main.bundleIdentifier || FocusedFieldSnapshot.isExcluded(bundleID: frontmost) {
      return nil
    }
    guard let windowID = ScreenshotDisplayPicker.frontmostWindowID() else { return nil }

    var content: SCShareableContent
    let now = Date()
    if let cached = cachedShareableContent,
       let ts = cachedShareableContentDate,
       now.timeIntervalSince(ts) < shareableContentCacheDuration {
      content = cached
    } else {
      do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedShareableContent = content
        cachedShareableContentDate = now
      } catch {
        return nil
      }
    }

    if !content.windows.contains(where: { $0.windowID == windowID }),
       let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
      content = fresh
      cachedShareableContent = fresh
      cachedShareableContentDate = Date()
    }

    guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
    let filter = SCContentFilter(desktopIndependentWindow: window)

    var config = SCStreamConfiguration()
    config.capturesAudio = false
    config.width = Int(filter.contentRect.width) * Int(filter.pointPixelScale)
    config.height = Int(filter.contentRect.height) * Int(filter.pointPixelScale)
    guard config.width > 0, config.height > 0 else { return nil }

    let cgImage: CGImage? = await withCheckedContinuation { continuation in
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
        continuation.resume(returning: image)
      }
    }
    guard let cgImage else { return nil }
    return Self.jpegData(cgImage, maxLongerSide: 1400, quality: 0.75)
  }

  /// JPEG of `image`, scaled so the longer side is at most `maxLongerSide`. Images already
  /// within that limit are encoded as they are. Nil when a needed downscale context cannot be
  /// created: the full-size image is never sent.
  private static func jpegData(_ image: CGImage, maxLongerSide: Int, quality: CGFloat) -> Data? {
    let longer = max(image.width, image.height)
    let finalImage: CGImage
    if longer > maxLongerSide, longer > 0 {
      let scale = CGFloat(maxLongerSide) / CGFloat(longer)
      let newWidth = image.width >= image.height ? maxLongerSide : max(1, Int(CGFloat(image.width) * scale))
      let newHeight = image.height > image.width ? maxLongerSide : max(1, Int(CGFloat(image.height) * scale))
      let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
      guard let ctx = CGContext(
        data: nil, width: newWidth, height: newHeight,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else { return nil }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
      guard let scaled = ctx.makeImage() else { return nil }
      finalImage = scaled
    } else {
      finalImage = image
    }
    let rep = NSBitmapImageRep(cgImage: finalImage)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
  }

  /// Captures the display that contains the chat window, excluding this app's windows via ScreenCaptureKit.
  /// Returns PNG data or nil on failure (e.g. no Screen Recording permission).
  @MainActor
  func captureScreenExcludingChatWindow() async -> Data? {
    guard windowController?.window != nil else {
      DebugLogger.log("GEMINI-SCREENSHOT: No window")
      return nil
    }

    // Always fetch fresh SCShareableContent for the chat capture path.
    // Using the cache caused the chat window to appear in screenshots:
    // prefetchShareableContent() runs right after showWindow(), often before
    // the window is actually on screen, so `applications` didn't contain
    // WhisperShortcut — and that stale snapshot lived in the cache for 30s,
    // making excludingApplications a no-op for every screenshot taken in
    // that window.
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      cachedShareableContent = content
      cachedShareableContentDate = Date()
    } catch {
      DebugLogger.log("GEMINI-SCREENSHOT: SCShareableContent failed: \(error.logDescription)")
      return nil
    }

    guard !content.displays.isEmpty else {
      DebugLogger.log("GEMINI-SCREENSHOT: No displays")
      return nil
    }

    let display = content.displays.first { d in
      guard let window = windowController?.window, let screen = window.screen else { return true }
      let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      return screenNumber.map { UInt32(truncating: $0) == d.displayID } ?? true
    } ?? content.displays[0]

    // Collect every on-screen window that belongs to us, by bundle ID. This
    // is belt-and-suspenders: excludingWindows is per-window and doesn't
    // depend on `applications` containing WhisperShortcut at snapshot time.
    let ourBundleID = Bundle.main.bundleIdentifier
    let ourWindows = content.windows.filter { window in
      window.owningApplication?.bundleIdentifier == ourBundleID
    }
    DebugLogger.log("GEMINI-SCREENSHOT: Excluding \(ourWindows.count) of our own window(s)")
    let filter = SCContentFilter(display: display, excludingWindows: ourWindows)

    var config = SCStreamConfiguration()
    config.capturesAudio = false
    config.width = Int(filter.contentRect.width) * Int(filter.pointPixelScale)
    config.height = Int(filter.contentRect.height) * Int(filter.pointPixelScale)

    let cgImage: CGImage? = await withCheckedContinuation { continuation in
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
        if let error = error {
          DebugLogger.log("GEMINI-SCREENSHOT: captureImage error: \(error.logDescription)")
        }
        continuation.resume(returning: image)
      }
    }

    guard let cgImage = cgImage else {
      DebugLogger.log("GEMINI-SCREENSHOT: No image (check Screen Recording permission)")
      return nil
    }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
      DebugLogger.log("GEMINI-SCREENSHOT: Failed to encode PNG")
      return nil
    }

    DebugLogger.log("GEMINI-SCREENSHOT: Captured \(pngData.count) bytes")
    return pngData
  }
}
