import AppKit
import Foundation

/// Where the running app bundle lives, as far as "should it be moved to Applications?" goes.
///
/// Kept outside `#if !APP_STORE` so the tests (which run against the App Store target) cover it;
/// only the direct build ever acts on it.
enum AppBundleLocation: Equatable {
  /// `/Applications` or `~/Applications` (or a folder inside either).
  case applications
  /// macOS App Translocation: a quarantined app launched where the user put it — typically
  /// straight from the downloaded disk image — runs from a random read-only path. Permissions
  /// granted to that copy do not stick, and it is missing from System Settings → Accessibility.
  case translocated
  /// A mounted disk image (`/Volumes/…`) that was not translocated.
  case diskImage
  /// Anywhere else, such as Downloads or the Desktop.
  case elsewhere
  /// A build product (Xcode DerivedData, a `build/` folder, an agent worktree). Never offered a move.
  case developerBuild

  var shouldOfferMove: Bool {
    switch self {
    case .translocated, .diskImage, .elsewhere: return true
    case .applications, .developerBuild: return false
    }
  }

  /// Classifies a bundle path. `homeDirectory` is the user's real home (not the sandbox
  /// container), for `~/Applications`.
  static func classify(bundlePath: String, homeDirectory: String) -> AppBundleLocation {
    let path = (bundlePath as NSString).standardizingPath
    if path.contains("/AppTranslocation/") { return .translocated }
    let home = (homeDirectory as NSString).standardizingPath
    for folder in ["/Applications", home + "/Applications"] where path.hasPrefix(folder + "/") {
      return .applications
    }
    if path.hasPrefix("/Volumes/") { return .diskImage }
    let buildMarkers = ["/DerivedData/", "/Build/Products/", "/.claude/worktrees/", "/build/"]
    if buildMarkers.contains(where: { path.contains($0) }) { return .developerBuild }
    return .elsewhere
  }
}

/// Whether to offer moving this copy into Applications. The dialog is direct-build only;
/// the decision is here so the App Store test target can cover "Not Now".
enum ApplicationsFolderMove {
  /// Passed to the relaunched copy, so a copy that still is not in Applications explains the
  /// manual way instead of offering the move a second time.
  static let movedArgument = "--moved-to-applications"

  /// True unless this exact bundle path was already declined with Not Now. A different path
  /// (a new download) is offered again.
  static func shouldOffer(currentPath: String, declinedPath: String?) -> Bool {
    currentPath != declinedPath
  }
}

#if !APP_STORE
  /// Offers to move the app into `/Applications` when it runs from anywhere else, most of all
  /// straight from the mounted disk image.
  ///
  /// A pilot user (2026-11-02) did exactly that: macOS translocated the app, and WhisperShortcut
  /// never showed up in System Settings → Accessibility, so she had to add it with "+", a file
  /// picker and a Touch ID prompt she did not understand. No third-party "LetsMove": the app is
  /// sandboxed, so the copy needs the user's OK for the Applications folder (an open panel)
  /// whenever the plain copy is refused.
  ///
  /// Not verified on a real Mac yet: whether the sandbox lets the app clear the quarantine
  /// attribute on its copy. If it does not, the relaunched copy may be translocated again; the
  /// `movedArgument` check below then shows the drag-it-yourself instructions instead of looping.
  @MainActor
  extension ApplicationsFolderMove {
    /// Shows the offer when the app runs outside Applications. Returns true when the app is
    /// relaunching from Applications and about to quit — the caller then skips the rest of launch.
    @discardableResult
    static func offerIfNeeded() -> Bool {
      #if DEBUG
        return false
      #else
        guard !AppConstants.isDevBuild, !AppConstants.isSidecarInstance else { return false }
        let bundleURL = Bundle.main.bundleURL
        let location = AppBundleLocation.classify(
          bundlePath: bundleURL.path, homeDirectory: realHomeDirectory)
        guard location.shouldOfferMove else { return false }
        let declinedPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.applicationsMoveDeclinedPath)
        guard shouldOffer(currentPath: bundleURL.path, declinedPath: declinedPath) else {
          DebugLogger.log("APP-LOCATION: Not Now already chosen for this path")
          return false
        }
        DebugLogger.log("APP-LOCATION: running from \(location) (\(bundleURL.path))")

        if ProcessInfo.processInfo.arguments.contains(movedArgument) {
          DebugLogger.logWarning("APP-LOCATION: still outside Applications after a move — showing instructions")
          showManualInstructions()
          return false
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Move WhisperShortcut to Applications?")
        alert.informativeText = String(
          localized:
            "WhisperShortcut is running from the downloaded disk image or another temporary place. From there, macOS does not keep its permissions, and it is missing from the Accessibility list. Move it to the Applications folder and open it from there."
        )
        alert.addButton(withTitle: String(localized: "Move and Relaunch"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
          UserDefaults.standard.set(bundleURL.path, forKey: UserDefaultsKeys.applicationsMoveDeclinedPath)
          DebugLogger.log("APP-LOCATION: user chose Not Now")
          return false
        }
        return moveAndRelaunch(bundleURL)
      #endif
    }

    // MARK: - Move

    private static func moveAndRelaunch(_ bundleURL: URL) -> Bool {
      let appName = bundleURL.lastPathComponent
      let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
      let destination = applications.appendingPathComponent(appName)

      if FileManager.default.fileExists(atPath: destination.path), !confirmReplace() {
        DebugLogger.log("APP-LOCATION: user kept the existing copy in Applications")
        return false
      }

      do {
        try install(bundleURL, at: destination)
      } catch {
        // The sandbox refuses writes outside the container until the user grants the folder.
        DebugLogger.log("APP-LOCATION: plain copy refused (\(error.localizedDescription)) — asking for the folder")
        guard let granted = askForApplicationsFolder() else {
          showManualInstructions()
          return false
        }
        let didAccess = granted.startAccessingSecurityScopedResource()
        defer { if didAccess { granted.stopAccessingSecurityScopedResource() } }
        do {
          try install(bundleURL, at: granted.appendingPathComponent(appName))
        } catch {
          DebugLogger.logError("APP-LOCATION: copy failed after the folder grant: \(error.localizedDescription)")
          showManualInstructions()
          return false
        }
        return relaunch(granted.appendingPathComponent(appName))
      }
      return relaunch(destination)
    }

    /// Copies next to the destination first and swaps it in only once the copy is complete, so a
    /// failed copy never costs the user the copy they already had (that one goes to the Trash).
    private static func install(_ source: URL, at destination: URL) throws {
      let fileManager = FileManager.default
      let staging = destination.deletingLastPathComponent()
        .appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
      try fileManager.copyItem(at: source, to: staging)
      do {
        if fileManager.fileExists(atPath: destination.path) {
          try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.moveItem(at: staging, to: destination)
      } catch {
        try? fileManager.removeItem(at: staging)
        throw error
      }
      let cleared = removeQuarantine(from: destination)
      DebugLogger.log("APP-LOCATION: copied to \(destination.path); quarantine cleared=\(cleared)")
    }

    /// Clears `com.apple.quarantine` on the copy only (never on the original), so the relaunched app
    /// is not translocated again. Returns whether the bundle itself is free of it afterwards.
    private static func removeQuarantine(from bundle: URL) -> Bool {
      let attribute = "com.apple.quarantine"
      var paths = [bundle.path]
      if let enumerator = FileManager.default.enumerator(atPath: bundle.path) {
        for case let relative as String in enumerator {
          paths.append(bundle.appendingPathComponent(relative).path)
        }
      }
      for path in paths {
        removexattr(path, attribute, XATTR_NOFOLLOW)
      }
      return getxattr(bundle.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) < 0
    }

    /// Same detached `open -n` as the permissions relaunch (`PermissionsOverview.relaunchApp`): the
    /// single-instance check would make a copy started while this process still runs exit at once.
    private static func relaunch(_ appURL: URL) -> Bool {
      let quotedPath = "'" + appURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
      let command =
        "( /bin/sleep 1 && /usr/bin/open -n \(quotedPath) --args \(movedArgument) ) >/dev/null 2>&1 &"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.standardInput = nil
      process.standardOutput = nil
      process.standardError = nil
      do {
        try process.run()
      } catch {
        DebugLogger.logError("APP-LOCATION: relaunch helper failed: \(error.localizedDescription)")
        showManualInstructions()
        return false
      }
      DebugLogger.log("APP-LOCATION: relaunching from \(appURL.path); terminating this copy")
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.shouldTerminate)
      NSApp.terminate(nil)
      return true
    }

    // MARK: - Dialogs

    private static func confirmReplace() -> Bool {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = String(localized: "Replace the copy in Applications?")
      alert.informativeText = String(
        localized:
          "There already is a WhisperShortcut in the Applications folder. It goes to the Trash and this one takes its place. Your settings and keys are kept."
      )
      alert.addButton(withTitle: String(localized: "Replace"))
      alert.addButton(withTitle: String(localized: "Cancel"))
      return alert.runModal() == .alertFirstButtonReturn
    }

    /// The sandbox's way to write into Applications: the user picks the folder once. Accepts only
    /// `/Applications` or `~/Applications`.
    private static func askForApplicationsFolder() -> URL? {
      let panel = NSOpenPanel()
      panel.message = String(
        localized: "macOS needs your OK to copy WhisperShortcut into the Applications folder. Click “Move Here”.")
      panel.prompt = String(localized: "Move Here")
      panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = false
      NSApp.activate(ignoringOtherApps: true)
      guard panel.runModal() == .OK, let url = panel.url else { return nil }
      let location = AppBundleLocation.classify(
        bundlePath: url.appendingPathComponent("WhisperShortcut.app").path,
        homeDirectory: realHomeDirectory)
      guard location == .applications else {
        DebugLogger.logWarning("APP-LOCATION: user picked \(url.path), not an Applications folder")
        return nil
      }
      return url
    }

    /// No write permission, a refused grant, or a copy that is still translocated: say how to do
    /// it by hand, and open the Applications folder to drag into.
    private static func showManualInstructions() {
      let alert = NSAlert()
      alert.alertStyle = .informational
      alert.messageText = String(localized: "Move WhisperShortcut yourself")
      alert.informativeText = String(
        localized:
          "Quit WhisperShortcut, then drag it from the disk image window into the Applications folder and open it from there. If macOS asks for your password, that is macOS confirming the copy."
      )
      alert.addButton(withTitle: String(localized: "Open Applications Folder"))
      alert.addButton(withTitle: String(localized: "OK"))
      NSApp.activate(ignoringOtherApps: true)
      if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
      }
    }

    /// The user's real home folder. In the sandbox `NSHomeDirectory()` is the container.
    private static var realHomeDirectory: String {
      if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
        return String(cString: dir)
      }
      return NSHomeDirectory()
    }
  }
#endif
