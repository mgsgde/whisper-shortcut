import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// User-facing error copy for billing, rate limits, file/model failures, and the popup
/// title/body split. A wrong branch here either lists three dashboards for a known empty
/// balance or repeats the heading in the body.
@Suite("SpeechErrorFormatter popups")
struct SpeechErrorFormatterPopupTests {

  struct FormatBranch: Sendable {
    let label: String
    let error: TranscriptionError
    let mustContain: [String]
    let mustNotContain: [String]
  }

  @Test("format() picks the right copy per error branch", arguments: [
    FormatBranch(label: "OpenAI billing uses OpenAI out-of-credit copy",
           error: .billingRequired(topUpURL: TranscriptionError.openAIBillingURL),
           mustContain: ["OpenAI", "Out of Credit"], mustNotContain: ["OpenRouter"]),
    FormatBranch(label: "non-OpenAI top-up URL uses OpenRouter copy",
           error: .billingRequired(topUpURL: URL(string: "https://openrouter.ai/settings/credits")!),
           mustContain: ["OpenRouter"], mustNotContain: ["platform.openai.com"]),
    FormatBranch(label: "billing without URL lists every provider dashboard",
           error: .billingRequired(),
           mustContain: ["aistudio.google.com", "platform.openai.com", "console.x.ai"], mustNotContain: []),
    FormatBranch(label: "rate limit with top-up URL is the daily-limit copy",
           error: .rateLimited(retryAfter: nil, topUpURL: URL(string: "https://example.com/topup")!),
           mustContain: ["Daily Limit Reached"], mustNotContain: ["aistudio.google.com"]),
    FormatBranch(label: "transient rate limit includes retry-after seconds",
           error: .rateLimited(retryAfter: 30, topUpURL: nil),
           mustContain: ["30", "Rate Limit Exceeded"], mustNotContain: []),
    FormatBranch(label: "fileError mentioning a missing model points at Offline Models",
           error: .fileError("Model not found on disk"),
           mustContain: ["Model Not Downloaded", "Download"], mustNotContain: []),
    FormatBranch(label: "generic fileError stays a file error",
           error: .fileError("could not read wav header"),
           mustContain: ["File Error", "could not read wav header"], mustNotContain: ["Offline Models"]),
    FormatBranch(label: "networkError mentioning timeout uses the timeout copy",
           error: .networkError("The request timeout was reached"),
           mustContain: ["Generic Timeout", "The request timeout was reached"], mustNotContain: []),
    FormatBranch(label: "networkError without timeout language stays a network error",
           error: .networkError("connection reset"),
           mustContain: ["Network Error", "connection reset"], mustNotContain: []),
  ])
  func formatBranches(_ row: FormatBranch) {
    let message = SpeechErrorFormatter.format(row.error)
    for needle in row.mustContain { #expect(message.contains(needle), "\(row.label): missing \(needle)") }
    for needle in row.mustNotContain { #expect(!message.contains(needle), "\(row.label): unexpected \(needle)") }
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
}
