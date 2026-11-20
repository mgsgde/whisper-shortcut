import AppKit
import Foundation

/// The prefilled email a report opens in, with the context that makes it actionable.
///
/// Prefilling is the whole point. A report that arrives without an app version, the macOS
/// version, or the caller's own text costs a round-trip before anything can be done with it.
/// Building the message in one place means every entry point attaches the same facts. The user
/// still presses send in their mail app; nothing leaves the Mac from here.
enum FeedbackLinks {

  /// Where a report's text can be opened. The report window is the only feedback path; email is
  /// how that window sends.
  enum Channel: String, CaseIterable {
    case email
  }

  /// Support email — the address already published in SECURITY.md and PRIVACY.md, so it is the
  /// one users may have seen elsewhere.
  static let supportEmail = "mgsgde@gmail.com"

  /// Subject line for a report email. Shared by the `mailto:` URL and Mail's compose service so
  /// both drafts are titled the same way.
  static var emailSubject: String {
    String(localized: "WhisperShortcut feedback (\(AppConstants.appVersion))")
  }

  // MARK: - Opening

  /// Opens `channel` with a message pre-composed from the app's environment plus `context`.
  ///
  /// `context` is whatever the caller knows that the user shouldn't have to retype — the text of
  /// the error they just hit, or the tail of the chat they were having. It is *prefilled*, never
  /// sent: Mail opens with the text visible and the user presses send, so nothing about their
  /// conversation leaves the machine without them seeing it first.
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
    case .email:
      guard let subject = encode(emailSubject),
            let encoded = encode(body) else { return nil }
      return URL(string: "mailto:\(supportEmail)?subject=\(subject)&body=\(encoded)")
    }
  }

  /// The message every channel starts from: a greeting, the caller's context, and the environment
  /// facts a report is useless without.
  static func messageBody(context: String? = nil) -> String {
    var parts = [String(localized: "Hi! I have feedback about WhisperShortcut:")]
    if let context = context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
      parts.append(context)
    }
    if let hang = HangReports.feedbackAttachment() {
      parts.append(hang)
    }
    parts.append(environmentBlock)
    return parts.joined(separator: "\n\n")
  }

  /// Truncates `text` to `limit` characters. `mailto:` carries its payload in the URL, and an
  /// over-long URL is silently dropped by some mail clients rather than erroring — so callers
  /// attaching free-form context clamp it here.
  static func truncated(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit)) + "…"
  }

  static var environmentBlock: String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let version = AppConstants.appVersion
    let versionLine = String(localized: "App version: \(version)")
    return """
      ---
      \(versionLine)
      macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
      """
  }

  /// `.urlQueryAllowed` keeps `&`, `=`, `+` and `?` literal, which is right for a whole query but
  /// wrong for one value: "Anamnese & Befund" would end the body at the `&`, and `+` arrives as a space.
  private static let queryValueAllowed: CharacterSet = {
    var set = CharacterSet.urlQueryAllowed
    set.remove(charactersIn: "&=+?#")
    return set
  }()

  private static func encode(_ text: String) -> String? {
    text.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
  }
}
