//
//  WritingContextResolver.swift
//  WhisperShortcut
//
//  Maps the app the user is writing in to a writing-style bucket. Dictate Prompt runs while the
//  menu bar app stays in the background, so the frontmost application at request time is the one
//  the draft is meant for. See plans/active/writing-style.md.
//

import AppKit
import Foundation

enum WritingContext: String, Codable, CaseIterable {
  case email
  case messenger
  case workChat
  case defaultContext = "default"

  var displayName: String {
    switch self {
    case .email: return "Email"
    case .messenger: return "Messenger"
    case .workChat: return "Work Chat"
    case .defaultContext: return "Default"
    }
  }

  /// Section header in `profile.md`, same `=== … ===` convention as `system-prompts.md`.
  var profileHeader: String { "=== \(displayName) ===" }
}

enum WritingContextResolver {

  private static let bundleIDs: [WritingContext: Set<String>] = [
    .email: [
      "com.apple.mail",
      "com.microsoft.outlook",
      "com.readdle.smartemail-mac",
      "com.readdle.sparkdesktop",
      "it.bloop.airmail2",
      "com.superhuman.electron",
      "com.mimestream.mimestream",
      "org.mozilla.thunderbird",
    ],
    .messenger: [
      "net.whatsapp.whatsapp",
      "desktop.whatsapp",
      "org.whispersystems.signal-desktop",
      "com.apple.mobilesms",
      "ru.keepcoder.telegram",
      "com.tdesktop.telegram",
    ],
    .workChat: [
      "com.tinyspeck.slackmacgap",
      "com.microsoft.teams2",
      "com.microsoft.teams",
    ],
  ]

  /// Browsers and every unknown app fall through to `.defaultContext`: a browser tab could be
  /// Gmail or WhatsApp Web, and guessing wrong is worse than using the neutral profile.
  static func context(forBundleID bundleID: String?) -> WritingContext {
    guard let id = bundleID?.lowercased() else { return .defaultContext }
    for (context, ids) in bundleIDs where ids.contains(id) {
      return context
    }
    return .defaultContext
  }

  static func current() -> WritingContext {
    context(forBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
  }
}
