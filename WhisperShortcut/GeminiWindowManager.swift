import Cocoa
import ScreenCaptureKit

class GeminiWindowManager {
  static let shared = GeminiWindowManager()
  private var windowController: GeminiWindowController?

  private init() {}

  func toggle() {
    if isWindowOpen() {
      close()
    } else {
      show()
    }
  }

  func show() {
    if windowController == nil {
      windowController = GeminiWindowController()
    }
    windowController?.showWindow()
  }

  func close() {
    windowController?.window?.close()
  }

  func isWindowOpen() -> Bool {
    guard let window = windowController?.window else { return false }
    return window.isVisible
  }

  /// Captures the display that contains the Gemini window, excluding this app's windows via ScreenCaptureKit.
  /// Returns PNG data or nil on failure (e.g. no Screen Recording permission).
  @MainActor
  func captureScreenExcludingGeminiWindow() async -> Data? {
    guard windowController?.window != nil else {
      DebugLogger.log("GEMINI-SCREENSHOT: No window")
      return nil
    }

    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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

    let ourApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
    let filter = SCContentFilter(display: display, excludingApplications: ourApp.map { [$0] } ?? [], exceptingWindows: [])

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
