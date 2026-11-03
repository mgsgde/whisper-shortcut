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

  @Test("Fractional 'Please retry in Xs' is parsed")
  func parseFractionalRetryDelay() {
    #expect(
      GeminiErrorResponse.parseRetryDelayFromMessage("Please retry in 55.764008118s.")
        == 55.764008118)
  }

  @Test("Integer 'retry in Ns' is parsed")
  func parseIntegerRetryDelay() {
    #expect(GeminiErrorResponse.parseRetryDelayFromMessage("retry in 30s") == 30)
  }

  @Test("A message with no retry delay returns nil")
  func parseMissingRetryDelay() {
    #expect(GeminiErrorResponse.parseRetryDelayFromMessage("Resource exhausted") == nil)
    #expect(GeminiErrorResponse.parseRetryDelayFromMessage("") == nil)
  }

  // MARK: - redactingAPIKey

  @Test("A key query item is replaced with REDACTED")
  func redactsKeyQueryItem() {
    let url = "https://example.com/v1/models?key=SECRET&alt=json"
    let redacted = GeminiAPIClient.redactingAPIKey(url)
    #expect(redacted.contains("key=REDACTED"))
    #expect(!redacted.contains("SECRET"))
    #expect(redacted.contains("alt=json"))
  }

  @Test("KEY is matched case-insensitively")
  func redactsUppercaseKey() {
    let redacted = GeminiAPIClient.redactingAPIKey("https://example.com/v1?KEY=secret-value")
    #expect(redacted.contains("REDACTED"))
    #expect(!redacted.contains("secret-value"))
  }

  @Test("A non-URL string is returned unchanged")
  func nonURLIsUnchanged() {
    #expect(GeminiAPIClient.redactingAPIKey("not a url") == "not a url")
  }

  @Test("api_key is not treated as the Gemini key parameter")
  func apiKeyQueryItemIsNotRedacted() {
    // Current contract: only the query name `key` is stripped. `api_key` is a different
    // parameter (used by other providers) and is left as-is.
    let url = "https://example.com/v1?api_key=still-visible"
    let redacted = GeminiAPIClient.redactingAPIKey(url)
    #expect(redacted.contains("still-visible"))
    #expect(!redacted.contains("REDACTED"))
  }

  // MARK: - GeminiCredential

  @Test("Bearer credentials are the SSO/proxy path")
  func bearerIsOAuth() {
    #expect(!GeminiCredential.apiKey("abc").isOAuth)
    #expect(GeminiCredential.bearer("id-token").isOAuth)
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

  @Test("401 plus an api-key message is invalidAPIKey")
  func unauthorizedAPIKey() throws {
    let data = try geminiError(code: 401, message: "API key not valid. Please pass a valid API key.")
    #expect(try client.parseErrorResponse(data: data, statusCode: 401) == .invalidAPIKey)
  }

  @Test("A non-401 api-key message is incorrectAPIKey")
  func incorrectAPIKeyOnNon401() throws {
    let data = try geminiError(code: 400, message: "API key expired or authentication failed")
    #expect(try client.parseErrorResponse(data: data, statusCode: 400) == .incorrectAPIKey)
  }

  @Test("400 FAILED_PRECONDITION with billing language is billingRequired")
  func billingFailedPrecondition() throws {
    let data = try geminiError(
      code: 400,
      message: "This model requires billing to be enabled for the free tier.",
      status: "FAILED_PRECONDITION")
    #expect(try client.parseErrorResponse(data: data, statusCode: 400) == .billingRequired())
  }

  @Test("A quota message carries the parsed retry delay")
  func quotaExceededKeepsRetryDelay() throws {
    let data = try geminiError(
      code: 429,
      message: "You have exceeded your quota. Please retry in 12.5s.")
    #expect(
      try client.parseErrorResponse(data: data, statusCode: 429)
        == .quotaExceeded(retryAfter: 12.5))
  }

  @Test("'Rate limit exceeded' maps to rateLimited")
  func rateLimitExceededIsRateLimited() throws {
    let data = try geminiError(code: 429, message: "Rate limit exceeded. Please retry in 8s.")
    #expect(
      try client.parseErrorResponse(data: data, statusCode: 429)
        == .rateLimited(retryAfter: 8, topUpURL: nil))
  }

  @Test("A rate-limit message without 'exceeded' is rateLimited")
  func rateLimitWithoutExceeded() throws {
    let data = try geminiError(code: 429, message: "Hit a rate limit. Please retry in 4s.")
    #expect(
      try client.parseErrorResponse(data: data, statusCode: 429)
        == .rateLimited(retryAfter: 4, topUpURL: nil))
  }

  @Test("404 plus deprecated language is modelDeprecated")
  func deprecatedModel() throws {
    let data = try geminiError(
      code: 404,
      message: "This model is no longer available and has been deprecated.")
    #expect(try client.parseErrorResponse(data: data, statusCode: 404) == .modelDeprecated)
  }

  @Test("400 plus voice/allowlist language is voiceRequiresAPIKey")
  func voiceRequiresAPIKey() throws {
    let data = try geminiError(
      code: 400,
      message: "Audio output is allowlist-only.")
    #expect(try client.parseErrorResponse(data: data, statusCode: 400) == .voiceRequiresAPIKey)
  }

  @Test("A voice error that also says 'api key' is voiceRequiresAPIKey")
  func voicePhraseAlsoContainingAPIKey() throws {
    let data = try geminiError(
      code: 400,
      message: "Audio output requires an API key and allowlist access.")
    #expect(try client.parseErrorResponse(data: data, statusCode: 400) == .voiceRequiresAPIKey)
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
