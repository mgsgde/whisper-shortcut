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

  /// Picker label. Profile headers and text sent to the model use `englishName`.
  var displayName: String {
    switch self {
    case .email: return String(localized: "Email")
    case .messenger: return String(localized: "Messenger")
    case .workChat: return String(localized: "Work Chat")
    case .defaultContext: return String(localized: "Default")
    }
  }

  /// English name written into `profile.md` and into prompts. A language change must not
  /// rewrite those files or the text the model reads.
  var englishName: String {
    switch self {
    case .email: return "Email"
    case .messenger: return "Messenger"
    case .workChat: return "Work Chat"
    case .defaultContext: return "Default"
    }
  }

  /// Section header in `profile.md`, same `=== … ===` convention as `system-prompts.md`.
  var profileHeader: String { "=== \(englishName) ===" }
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

  /// Browsers. A tab is not an app: `context(forBundleID:)` still returns `.defaultContext` for
  /// these, and `context(forBundleID:webURL:)` resolves the tab's host only when it is one of the
  /// listed web apps. Anything else stays Default.
  private static let browserBundleIDs: Set<String> = [
    "com.apple.safari",
    "com.apple.safaritechnologypreview",
    "com.google.chrome",
    "com.google.chrome.beta",
    "com.microsoft.edgemac",
    "company.thebrowser.browser",
    "com.brave.browser",
    "com.vivaldi.vivaldi",
    "com.operasoftware.opera",
    "com.kagi.kagimacos",
    "org.mozilla.firefox",
  ]

  /// Web-app hosts. A host matches exactly or as a subdomain (`host == h || host.hasSuffix("." + h)`).
  private static let webHosts: [WritingContext: Set<String>] = [
    .email: [
      "mail.google.com",
      "outlook.office.com",
      "outlook.office365.com",
      "outlook.live.com",
      "mail.yahoo.com",
      "app.fastmail.com",
      "mail.proton.me",
    ],
    .messenger: [
      "web.whatsapp.com",
      "web.telegram.org",
      "messages.google.com",
      "app.signal.org",
    ],
    .workChat: [
      "teams.microsoft.com",
      "teams.live.com",
      "teams.cloud.microsoft",
      "app.slack.com",
    ],
  ]

  /// Known native apps map to a context. Browsers and every unknown app fall through to
  /// `.defaultContext` here. A browser resolves by the tab's host only when that host is one of
  /// the listed web apps; anything else stays Default (`context(forBundleID:webURL:)`).
  static func context(forBundleID bundleID: String?) -> WritingContext {
    guard let id = bundleID?.lowercased() else { return .defaultContext }
    for (context, ids) in bundleIDs where ids.contains(id) {
      return context
    }
    return .defaultContext
  }

  static func isBrowser(bundleID: String?) -> Bool {
    guard let id = bundleID?.lowercased() else { return false }
    return browserBundleIDs.contains(id)
  }

  /// A non-browser keeps `context(forBundleID:)`. A browser uses the tab host when it is a listed
  /// web app (exact host or a subdomain); every other tab, and a missing URL, stays `.defaultContext`.
  static func context(forBundleID bundleID: String?, webURL: URL?) -> WritingContext {
    guard isBrowser(bundleID: bundleID) else { return context(forBundleID: bundleID) }
    guard let host = webURL?.host?.lowercased(), !host.isEmpty else { return .defaultContext }
    for context in [WritingContext.email, .messenger, .workChat] {
      guard let hosts = webHosts[context] else { continue }
      if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
        return context
      }
    }
    return .defaultContext
  }

  static func current() -> WritingContext {
    let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    guard isBrowser(bundleID: bundleID) else {
      return context(forBundleID: bundleID)
    }
    return context(forBundleID: bundleID, webURL: FocusedWebURL.current())
  }
}
