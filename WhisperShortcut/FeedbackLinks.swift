import AppKit
import Foundation

/// Every way a user can reach the developer, with the context that makes a report actionable.
///
/// Two reasons this exists as one type rather than a URL built at each call site:
///
/// 1. **Prefilling is the whole point.** A report that arrives without an app version, the macOS
///    version, or the actual error text costs a round-trip before anything can be done with it.
///    Building the message in one place means every entry point attaches the same facts.
/// 2. **WhatsApp alone loses people.** `wa.me` is a good primary channel — it needs no contact
///    saved — but WhatsApp is regionally lopsided and blocked on many managed Macs. A user who
///    only sees "Contact me on WhatsApp" and has no WhatsApp simply doesn't report the bug.
enum FeedbackLinks {

  /// Where a report can go. Order is the order they are offered: WhatsApp first because it is the
  /// fastest for the people who have it, email as the universal fallback, GitHub for anyone who
  /// would rather file in public.
  enum Channel: String, CaseIterable {
    case whatsApp
    case email
    case gitHub

    var menuTitle: String {
      switch self {
      case .whatsApp: return "WhatsApp"
      case .email: return "Email"
      case .gitHub: return "GitHub Issue"
      }
    }

    var helpText: String {
      switch self {
      case .whatsApp: return "Message the developer on WhatsApp"
      case .email: return "Email the developer"
      case .gitHub: return "Open a GitHub issue"
      }
    }
  }

  /// Support email — the address already published in SECURITY.md and PRIVACY.md, so it is the
  /// one users may have seen elsewhere.
  static let supportEmail = "mgsgde@gmail.com"

  // MARK: - Opening

  /// Opens `channel` with a message pre-composed from the app's environment plus `context`.
  ///
  /// `context` is whatever the caller knows that the user shouldn't have to retype — the text of
  /// the error they just hit, or the tail of the chat they were having. It is *prefilled*, never
  /// sent: WhatsApp, Mail and GitHub all open with the text visible and the user presses send, so
  /// nothing about their conversation leaves the machine without them seeing it first.
  @discardableResult
  static func open(_ channel: Channel, context: String? = nil) -> Bool {
    guard let url = url(for: channel, context: context) else {
      DebugLogger.logError("FEEDBACK: Could not build \(channel.rawValue) URL")
      return false
    }
    let opened = NSWorkspace.shared.open(url)
    if !opened { DebugLogger.logError("FEEDBACK: Failed to open \(channel.rawValue)") }
    return opened
  }

  // MARK: - URL building

  static func url(for channel: Channel, context: String? = nil) -> URL? {
    let body = messageBody(context: context)
    switch channel {
    case .whatsApp:
      guard let encoded = encode(body) else { return nil }
      let url = URL(string: "https://wa.me/\(AppConstants.whatsappSupportNumber)?text=\(encoded)")
      // Keep the shape assertion the previous inline implementation had: a malformed number or a
      // mangled encoding must not turn this into a request to somewhere else entirely.
      guard let url, url.scheme == "https", url.host == "wa.me" else { return nil }
      return url
    case .email:
      guard let subject = encode("WhisperShortcut feedback (\(AppConstants.appVersion))"),
            let encoded = encode(body) else { return nil }
      return URL(string: "mailto:\(supportEmail)?subject=\(subject)&body=\(encoded)")
    case .gitHub:
      guard let encoded = encode(body) else { return nil }
      return URL(string: "\(AppConstants.githubRepositoryURL)/issues/new?body=\(encoded)")
    }
  }

  /// The message every channel starts from: a greeting, the caller's context, and the environment
  /// facts a report is useless without.
  static func messageBody(context: String? = nil) -> String {
    var parts = ["Hi! I have feedback about WhisperShortcut:"]
    if let context = context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
      parts.append(context)
    }
    if let hang = HangReports.feedbackAttachment() {
      parts.append(hang)
    }
    parts.append(environmentBlock)
    return parts.joined(separator: "\n\n")
  }

  /// Truncates `text` to `limit` characters. `wa.me` and `mailto:` both carry their payload in the
  /// URL, and an over-long URL is silently dropped by some browsers and mail clients rather than
  /// erroring — so callers attaching free-form context clamp it here.
  static func truncated(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit)) + "…"
  }

  private static var environmentBlock: String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return """
      ---
      App version: \(AppConstants.appVersion)
      macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
      """
  }

  private static func encode(_ text: String) -> String? {
    text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
  }
}
