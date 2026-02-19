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

  /// Returns the WhisperShortcut Application Support base URL (directory containing UserContext/, Meetings/, WhisperKit/).
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
}
