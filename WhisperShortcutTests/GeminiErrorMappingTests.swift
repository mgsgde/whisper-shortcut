import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Pins Gemini error JSON → `TranscriptionError` and the helpers that feed retries and logs.
/// Wrong mapping here sends the user the wrong popup (billing vs 401 vs retry) or leaks a key.
@Suite("Gemini error mapping")
struct GeminiErrorMappingTests {

  private let client = GeminiAPIClient()

  private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
  }

  private func geminiError(code: Int, message: String, status: String? = nil) throws -> Data {
    var detail: [String: Any] = ["code": code, "message": message]
    if let status { detail["status"] = status }
    return try json(["error": detail])
  }

  // MARK: - parseRetryDelayFromMessage

  @Test("'retry in Xs' is parsed (fractional or integer); a message without one returns nil", arguments: [
    ("Please retry in 55.764008118s.", 55.764008118 as Double?),
    ("retry in 30s", 30),
    ("Resource exhausted", nil),
    ("", nil),
  ])
  func parseRetryDelay(message: String, expected: Double?) {
    #expect(GeminiErrorResponse.parseRetryDelayFromMessage(message) == expected, "\(message)")
  }

  // MARK: - redactingAPIKey

  private struct RedactCase: Sendable {
    let url: String, contains: [String], excludes: [String], label: String
  }

  @Test("Only the key query item is redacted (case-insensitive); a non-URL and api_key are left as-is", arguments: [
    RedactCase(
      url: "https://example.com/v1/models?key=SECRET&alt=json",
      contains: ["key=REDACTED", "alt=json"], excludes: ["SECRET"], label: "key query item"),
    RedactCase(
      url: "https://example.com/v1?KEY=secret-value",
      contains: ["REDACTED"], excludes: ["secret-value"], label: "uppercase KEY"),
    RedactCase(
      url: "not a url", contains: ["not a url"], excludes: ["REDACTED"], label: "non-URL is unchanged"),
    // Current contract: only the query name `key` is stripped. `api_key` is a different
    // parameter (used by other providers) and is left as-is.
    RedactCase(
      url: "https://example.com/v1?api_key=still-visible",
      contains: ["still-visible"], excludes: ["REDACTED"], label: "api_key is not the Gemini key parameter"),
  ])
  private func redactsOnlyTheKeyParameter(_ c: RedactCase) {
    let redacted = GeminiAPIClient.redactingAPIKey(c.url)
    for text in c.contains { #expect(redacted.contains(text), "\(c.label): missing \(text)") }
    for text in c.excludes { #expect(!redacted.contains(text), "\(c.label): leaked \(text)") }
    if c.label == "non-URL is unchanged" { #expect(redacted == c.url, "\(c.label)") }
  }

  // MARK: - parseErrorResponse

  @Test("HTTP 402 maps to subscriptionRequired")
  func http402IsSubscriptionRequired() throws {
    let error = try client.parseErrorResponse(data: Data("{}".utf8), statusCode: 402)
    #expect(error == .subscriptionRequired)
  }

  @Test("Proxy 429 with top_up_url is a rate limit pointing at that URL")
  func proxy429UsesTopUpURL() throws {
    let data = try json([
      "error": "rate limited",
      "code": "rate_limit_exceeded",
      "top_up_url": "https://example.com/topup",
    ])
    let error = try client.parseErrorResponse(data: data, statusCode: 429)
    #expect(error == .rateLimited(retryAfter: nil, topUpURL: URL(string: "https://example.com/topup")))
  }

  private struct MappingCase: Sendable {
    let code: Int, message: String, status: String?, expected: TranscriptionError, label: String
  }

  @Test("Gemini error bodies map to the right TranscriptionError", arguments: [
    MappingCase(
      code: 401, message: "API key not valid. Please pass a valid API key.", status: nil,
      expected: .invalidAPIKey, label: "401 plus an api-key message is invalidAPIKey"),
    MappingCase(
      code: 400, message: "API key expired or authentication failed", status: nil,
      expected: .incorrectAPIKey, label: "a non-401 api-key message is incorrectAPIKey"),
    MappingCase(
      code: 400, message: "This model requires billing to be enabled for the free tier.",
      status: "FAILED_PRECONDITION", expected: .billingRequired(),
      label: "400 FAILED_PRECONDITION with billing language is billingRequired"),
    MappingCase(
      code: 429, message: "You have exceeded your quota. Please retry in 12.5s.", status: nil,
      expected: .quotaExceeded(retryAfter: 12.5), label: "a quota message carries the parsed retry delay"),
    MappingCase(
      code: 429, message: "Rate limit exceeded. Please retry in 8s.", status: nil,
      expected: .rateLimited(retryAfter: 8, topUpURL: nil), label: "'Rate limit exceeded' maps to rateLimited"),
    MappingCase(
      code: 429, message: "Hit a rate limit. Please retry in 4s.", status: nil,
      expected: .rateLimited(retryAfter: 4, topUpURL: nil),
      label: "a rate-limit message without 'exceeded' is rateLimited"),
    MappingCase(
      code: 404, message: "This model is no longer available and has been deprecated.", status: nil,
      expected: .modelDeprecated, label: "404 plus deprecated language is modelDeprecated"),
    MappingCase(
      code: 400, message: "Audio output is allowlist-only.", status: nil,
      expected: .voiceRequiresAPIKey, label: "400 plus voice/allowlist language is voiceRequiresAPIKey"),
    MappingCase(
      code: 400, message: "Audio output requires an API key and allowlist access.", status: nil,
      expected: .voiceRequiresAPIKey, label: "a voice error that also says 'api key' is voiceRequiresAPIKey"),
  ])
  private func mapsErrorBody(_ c: MappingCase) throws {
    let data = try geminiError(code: c.code, message: c.message, status: c.status)
    #expect(try client.parseErrorResponse(data: data, statusCode: c.code) == c.expected, "\(c.label)")
  }

  @Test("A typed-decode miss still reads error.message from loose JSON")
  func fallbackJSONParsing() throws {
    // `code` as a string fails `GeminiErrorResponse` decoding (code is Int) and must
    // still map via the manual JSON path. Status 400 (not 401): the status-only
    // fallback for 400 is `.invalidRequest`, so this is `.incorrectAPIKey` only when
    // the message is actually read. A 401 would be `.invalidAPIKey` either way.
    let data = try json([
      "error": [
        "code": "400",
        "message": "API key not valid",
        "status": "INVALID_ARGUMENT",
      ] as [String: Any],
    ])
    #expect(try client.parseErrorResponse(data: data, statusCode: 400) == .incorrectAPIKey)
  }

  @Test("Unknown bodies fall back to the HTTP status map", arguments: [
    (400, TranscriptionError.invalidRequest),
    (401, .invalidAPIKey),
    (403, .permissionDenied),
    (404, .notFound),
    (429, .rateLimited(retryAfter: nil, topUpURL: nil)),
    (500, .serverError(500)),
    (503, .serviceUnavailable),
    (599, .serverError(599)),
  ])
  func statusCodeFallback(status: Int, expected: TranscriptionError) throws {
    #expect(try client.parseErrorResponse(data: Data(), statusCode: status) == expected)
  }
}
