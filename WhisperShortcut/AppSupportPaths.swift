//
//  AppSupportPaths.swift
//  WhisperShortcut
//
//  Canonical Application Support path so sandbox and non-sandbox use the same directory.
//

import Foundation

enum AppSupportPaths {

  private static let appSupportSubfolderName = "WhisperShortcut"
  private static let defaultBundleID = "com.magnusgoedde.whispershortcut"

  /// Returns the WhisperShortcut Application Support base URL (directory containing context data (UserContext/), Meetings/, WhisperKit/).
  /// When sandboxed, uses the container path from FileManager. When not sandboxed, explicitly uses the container path
  /// so both run contexts use the same physical directory.
  static func whisperShortcutApplicationSupportURL() -> URL {
    if isSandboxed {
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      return appSupport.appendingPathComponent(appSupportSubfolderName)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let bundleID = Bundle.main.bundleIdentifier ?? defaultBundleID
    return home
      .appendingPathComponent("Library")
      .appendingPathComponent("Containers")
      .appendingPathComponent(bundleID)
      .appendingPathComponent("Data")
      .appendingPathComponent("Library")
      .appendingPathComponent("Application Support")
      .appendingPathComponent(appSupportSubfolderName)
  }

  private static var isSandboxed: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }

  /// Directory holding user-authored context files (system-prompts.md, memory.md).
  static func userContextURL() -> URL {
    whisperShortcutApplicationSupportURL().appendingPathComponent("UserContext")
  }

  /// Creates `url` (and intermediates) if it does not already exist. Best-effort; logging is left
  /// to callers since failures surface on the subsequent write.
  static func ensureDirectoryExists(_ url: URL) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
      try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  /// Returns the daily log directory used by `DebugLogger`. Resolves automatically to the
  /// container path under sandbox and to `~/Library/Logs/WhisperShortcut` otherwise.
  static func logsURL() -> URL {
    let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    return libraryDir.appendingPathComponent("Logs/WhisperShortcut")
  }

  /// Opt-in dump location for raw final assistant responses. Off by default; gated by
  /// `UserDefaultsKeys.saveRawAssistantResponses`. Files written here are 1:1 model output
  /// (post image-marker strip) — meant for diagnosing markdown rendering, not telemetry.
  static func debugRawResponsesURL() -> URL {
    whisperShortcutApplicationSupportURL()
      .appendingPathComponent("Debug")
      .appendingPathComponent("raw-responses")
  }
}
