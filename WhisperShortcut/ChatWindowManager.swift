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
  func prefetchShareableContent() {
    Task { @MainActor in
      guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
      cachedShareableContent = content
      cachedShareableContentDate = Date()
      DebugLogger.log("GEMINI-SCREENSHOT: SCShareableContent pre-fetched and cached")
    }
  }

  /// Captures the primary display for Dictate Prompt — no chat window required.
  /// Returns JPEG data (max 1920 px wide, 80 % quality) or nil on failure (missing permission, no display, etc.).
  @MainActor
  func captureScreenForPromptMode() async -> Data? {
    let content: SCShareableContent
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

    guard !content.displays.isEmpty else {
      return nil
    }

    let display = content.displays[0]
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
      DebugLogger.log("GEMINI-SCREENSHOT: SCShareableContent failed: \(error.localizedDescription)")
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
          DebugLogger.log("GEMINI-SCREENSHOT: captureImage error: \(error.localizedDescription)")
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
