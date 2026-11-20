import AppKit

extension NSRunningApplication {
  /// True for this very process (pid), not merely an app with our bundle id.
  var isCurrentProcess: Bool { processIdentifier == ProcessInfo.processInfo.processIdentifier }
}

extension NSWorkspace {
  /// True while one of our own windows (Settings, Chat, …) is the frontmost app.
  var isOwnAppFrontmost: Bool { frontmostApplication?.isCurrentProcess == true }
}
