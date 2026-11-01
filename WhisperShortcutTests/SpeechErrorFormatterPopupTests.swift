import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// User-facing error copy for billing, rate limits, file/model failures, and the popup
/// title/body split. A wrong branch here either lists three dashboards for a known empty
/// balance or repeats the heading in the body.
@Suite("SpeechErrorFormatter popups")
struct SpeechErrorFormatterPopupTests {

  @Test("OpenAI billing uses the OpenAI-specific out-of-credit copy")
  func openAIBillingCopy() {
    let message = SpeechErrorFormatter.format(
      .billingRequired(topUpURL: TranscriptionError.openAIBillingURL))
    #expect(message.contains("OpenAI"))
    #expect(message.contains("Out of Credit") || message.contains("no credit"))
    #expect(!message.contains("OpenRouter"))
  }

  @Test("A non-OpenAI top-up URL uses the OpenRouter out-of-credit copy")
  func openRouterBillingCopy() {
    let url = URL(string: "https://openrouter.ai/settings/credits")!
    let message = SpeechErrorFormatter.format(.billingRequired(topUpURL: url))
    #expect(message.contains("OpenRouter"))
    #expect(!message.contains("platform.openai.com"))
  }

  @Test("Billing without a known URL lists every provider dashboard")
  func genericBillingListsDashboards() {
    let message = SpeechErrorFormatter.format(.billingRequired())
    #expect(message.contains("aistudio.google.com"))
    #expect(message.contains("platform.openai.com"))
    #expect(message.contains("console.x.ai"))
  }

  @Test("A rate limit with a top-up URL is the daily-limit copy")
  func rateLimitWithTopUpIsDailyLimit() {
    let url = URL(string: "https://example.com/topup")!
    let message = SpeechErrorFormatter.format(.rateLimited(retryAfter: nil, topUpURL: url))
    #expect(message.contains("Daily Limit") || message.contains("included usage"))
    #expect(!message.contains("aistudio.google.com"))
  }

  @Test("A transient rate limit includes the retry-after seconds")
  func rateLimitRetryAfterSeconds() {
    let message = SpeechErrorFormatter.format(.rateLimited(retryAfter: 30, topUpURL: nil))
    #expect(message.contains("30"))
    #expect(message.contains("Rate Limit") || message.contains("usage limits"))
  }

  @Test("A fileError that mentions a missing model points at Offline Models")
  func fileErrorModelNotFound() {
    let message = SpeechErrorFormatter.format(.fileError("Model not found on disk"))
    #expect(message.contains("Model Not Downloaded") || message.contains("Offline Models"))
    #expect(message.contains("Download"))
  }

  @Test("A generic fileError stays a file error")
  func genericFileError() {
    let message = SpeechErrorFormatter.format(.fileError("could not read wav header"))
    #expect(message.contains("File Error"))
    #expect(message.contains("could not read wav header"))
    #expect(!message.contains("Offline Models"))
  }

  @Test("A networkError whose details mention timeout uses the timeout copy")
  func networkTimeoutCopy() {
    let message = SpeechErrorFormatter.format(.networkError("The request timeout was reached"))
    #expect(message.contains("Timeout") || message.contains("timed out"))
    #expect(message.contains("The request timeout was reached"))
  }

  @Test("A networkError without timeout language stays a network error")
  func genericNetworkError() {
    let message = SpeechErrorFormatter.format(.networkError("connection reset"))
    #expect(message.contains("Network Error"))
    #expect(message.contains("connection reset"))
  }

  @Test("bodyWithoutHeading drops an exact title prefix")
  func dropsExactTitlePrefix() {
    let body = SpeechErrorFormatter.bodyWithoutHeading(
      "❌ Incorrect API Key\n\nThe API key provided is not correct.",
      title: "❌ Incorrect API Key")
    #expect(body.hasPrefix("The API key"))
    #expect(!body.contains("❌ Incorrect API Key"))
  }

  @Test("bodyWithoutHeading drops a same-symbol differently worded heading")
  func dropsSameSymbolHeading() {
    let (title, body) = SpeechErrorFormatter.titleAndBodyForPopup(
      .billingRequired(topUpURL: TranscriptionError.openAIBillingURL))
    #expect(title.hasPrefix("💳"))
    #expect(!body.hasPrefix("💳"), "body still opens with a heading: \(body.prefix(40))")
    #expect(!body.isEmpty)
  }

  @Test("titleAndBodyForPopupForUser falls back for a non-TranscriptionError")
  func genericErrorPopup() {
    let error = NSError(domain: "test", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "something broke",
    ])
    let (title, body) = SpeechErrorFormatter.titleAndBodyForPopupForUser(error)
    #expect(title == "Error")
    #expect(body == "something broke")
  }
}
