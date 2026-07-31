import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers the URL building behind every "contact the developer" entry point.
///
/// This fails silently in the worst way: a mis-encoded `?text=` or a broken `mailto:` doesn't
/// throw, it just opens a blank draft — or nothing at all — and the report the user was about to
/// send is lost without either side noticing.
@Suite("Feedback links")
struct FeedbackLinksTests {

  @Test("Every channel produces a URL, and each points where it should")
  func everyChannelBuilds() {
    for channel in FeedbackLinks.Channel.allCases {
      guard let url = FeedbackLinks.url(for: channel) else {
        Issue.record("\(channel.rawValue) produced no URL")
        continue
      }
      switch channel {
      case .whatsApp:
        #expect(url.scheme == "https")
        #expect(url.host == "wa.me")
      case .email:
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.contains(FeedbackLinks.supportEmail))
      case .gitHub:
        #expect(url.host == "github.com")
        #expect(url.path.hasSuffix("/issues/new"))
      }
    }
  }

  @Test("The message carries the facts a report is useless without")
  func messageCarriesEnvironment() {
    let body = FeedbackLinks.messageBody()
    #expect(body.contains(AppConstants.appVersion))
    #expect(body.contains("macOS:"))
  }

  @Test("Caller context is included, and absent context leaves no empty section")
  func contextIsIncluded() {
    let withContext = FeedbackLinks.messageBody(context: "I encountered this error: boom")
    #expect(withContext.contains("boom"))

    let withoutContext = FeedbackLinks.messageBody(context: "   ")
    #expect(!withoutContext.contains("\n\n\n"))
  }

  @Test("Newlines and reserved characters survive encoding into the query")
  func specialCharactersAreEncoded() {
    // A real error text: newlines, an ampersand, a hash, and a plus all have meaning in a URL.
    let context = "Line one\nLine two & three #4 + more"
    guard let url = FeedbackLinks.url(for: .whatsApp, context: context) else {
      Issue.record("no URL")
      return
    }
    // The raw characters must not appear unencoded in the query, or the message is truncated at
    // the first one the URL parser treats as a delimiter.
    let query = url.query ?? ""
    #expect(!query.contains("\n"))
    #expect(!query.contains(" "))
    // …and must come back out intact.
    #expect(url.absoluteString.removingPercentEncoding?.contains("Line two & three #4") == true)
  }

  @Test("Over-long context is clamped rather than silently dropped by the URL handler")
  func longContextIsTruncated() {
    let long = String(repeating: "x", count: 5_000)
    let clamped = FeedbackLinks.truncated(long, limit: 500)
    #expect(clamped.count == 501)  // 500 characters plus the ellipsis
    #expect(clamped.hasSuffix("…"))

    let short = "already short"
    #expect(FeedbackLinks.truncated(short, limit: 500) == short)
  }
}
