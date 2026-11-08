import AppKit
import Foundation

/// Swaps the user's all-day instance between the installed release and the daily Dev build
/// (`scripts/dev-daily.sh`). The new instance is launched with `--takeover`, which makes the
/// running one quit (see `FullWhisperShortcut.requestTakeover`).
/// Deliberately not @MainActor: `MenuBarController` calls it from nonisolated code. The UI part hops
/// to the main actor itself.
enum DailyInstanceSwitcher {
  private static let releaseID = "com.magnusgoedde.whispershortcut"

  private static func isInstalled(path: String, bundleID: String) -> URL? {
    NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).first {
      $0.standardizedFileURL.path == path
    }
  }

  /// The instance to switch to, or nil (no menu item) for sidecars, DerivedData Dev builds and
  /// the App Store build.
  static var target: (url: URL, title: String)? {
    let myPath = Bundle.main.bundleURL.standardizedFileURL.path
    if AppConstants.isDailyDevInstance {
      guard let url = isInstalled(path: AppConstants.releaseAppPath, bundleID: releaseID) else { return nil }
      return (url, "Switch to Release Build")
    }
    if !AppConstants.isDevBuild, myPath == AppConstants.releaseAppPath {
      guard let url = isInstalled(path: AppConstants.dailyDevAppPath, bundleID: releaseID + ".dev") else { return nil }
      return (url, "Switch to Dev Build")
    }
    return nil
  }

  static func switchNow() {
    guard let target else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = [AppConstants.takeoverArgument]
    NSWorkspace.shared.openApplication(at: target.url, configuration: configuration) { _, error in
      Task { @MainActor in
        if let error {
          DebugLogger.logError("SWITCHER: launching \(target.url.path) failed: \(error.localizedDescription)")
          let alert = NSAlert()
          alert.alertStyle = .warning
          alert.messageText = "Could not switch builds"
          alert.informativeText = error.localizedDescription
          alert.runModal()
        } else {
          DebugLogger.log("SWITCHER: launched \(target.url.path), quitting")
          UserDefaults.standard.set(true, forKey: UserDefaultsKeys.shouldTerminate)
          NSApp.terminate(nil)
        }
      }
    }
  }
}
