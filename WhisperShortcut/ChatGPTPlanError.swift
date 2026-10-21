import Foundation

/// Why a request on the user's ChatGPT plan failed, with the exact user-facing wording.
///
/// Usage errors stop inference: OpenAI never silently switches the request to another billing path,
/// and none of these loop through OAuth. Maps both pre-stream HTTP errors (`{"error":{…}}` or the
/// admission form `{"detail":"…"}`) and `response.failed` events that arrive mid-stream.
enum ChatGPTPlanError: LocalizedError, Equatable {
  /// `subscription_sharing_usage_limit_exceeded` (429): the plan's or this app's limit is reached.
  case usageLimit
  /// `subscription_sharing_user_not_eligible` (403): plan, workspace or policy forbids it.
  case notEligible
  /// `subscription_sharing_usage_unavailable` / `_user_unavailable` / admission 503: try again later.
  case usageUnavailable
  /// 401, `subscription_sharing_invalid_user`, a terminal refresh error, or no tokens at all.
  case signInRequired
  /// Signed in, but `chatgpt.tokens.use.direct` was not granted.
  case planNotEnabled
  /// `subscription_sharing_unsupported_capability` (400); `param` says which part.
  case unsupportedCapability(param: String?)
  /// Anything else; keeps the HTTP status (nil mid-stream) and the request id when there is one.
  case other(status: Int?, message: String, requestID: String?)

  var errorDescription: String? {
    switch self {
    case .usageLimit:
      return "You've reached the ChatGPT plan limit for WhisperShortcut. Check or raise it in ChatGPT Settings → Usage."
    case .notEligible:
      return "Your ChatGPT plan or workspace doesn't allow use in WhisperShortcut. Pick another chat model, or add an API key in Settings → Accounts."
    case .usageUnavailable:
      return "ChatGPT couldn't check your plan usage right now. Try again in a minute."
    case .signInRequired:
      return "Your ChatGPT sign-in has expired. Sign in again in Settings → Accounts."
    case .planNotEnabled:
      return "ChatGPT plan use wasn't allowed when you signed in. Turn it on in Settings → Accounts."
    case .unsupportedCapability(let param):
      return "Your ChatGPT plan can't run part of this request (\(param ?? "unknown")). Remove it and try again."
    case .other(let status, let message, let requestID):
      var text = status.map { "ChatGPT returned an error (HTTP \($0)): \(message)" }
        ?? "ChatGPT returned an error: \(message)"
      if let requestID, !requestID.isEmpty { text += " (request ID: \(requestID))" }
      return text
    }
  }

  // MARK: - Mapping

  /// The shared table. `code`/`param` come from `error.code` / `error.param`; with no code the HTTP
  /// status decides (admission errors only carry `{"detail": …}`).
  static func map(
    status: Int?, code: String?, param: String?, message: String?, requestID: String?
  ) -> ChatGPTPlanError {
    switch code {
    case "subscription_sharing_usage_limit_exceeded": return .usageLimit
    case "subscription_sharing_user_not_eligible": return .notEligible
    case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
      return .usageUnavailable
    case "subscription_sharing_unsupported_capability": return .unsupportedCapability(param: param)
    case "subscription_sharing_invalid_user": return .signInRequired
    default: break
    }
    if code == nil {
      if status == 401 { return .signInRequired }
      if status == 503 { return .usageUnavailable }
    }
    let text = (message?.isEmpty == false ? message : nil) ?? code ?? "request failed"
    return .other(status: status, message: text, requestID: requestID)
  }

  /// Maps a non-2xx response body. Handles `{"error":{code,message,param}}` and `{"detail":"…"}`.
  static func fromHTTP(status: Int, body: String) -> ChatGPTPlanError {
    let json = body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let error = json?["error"] as? [String: Any]
    let message = (error?["message"] as? String) ?? (json?["detail"] as? String)
      ?? (json?["error"] as? String)
      ?? (body.isEmpty ? nil : String(body.prefix(200)))
    return map(
      status: status,
      code: error?["code"] as? String,
      param: error?["param"] as? String,
      message: message,
      requestID: requestID(in: json, error: error, message: message))
  }

  /// Maps a terminal stream event: `response.failed`, `response.incomplete`, an `error` event, or
  /// `stream_ended` (the stream closed without `response.completed`).
  static func fromStreamFailure(type: String, payload: [String: Any]) -> ChatGPTPlanError {
    switch type {
    case "response.failed":
      // The documented shape nests the error under `response`; accept a top-level one too.
      let error = (payload["response"] as? [String: Any])?["error"] as? [String: Any]
        ?? payload["error"] as? [String: Any]
      let message = error?["message"] as? String
      return map(
        status: nil, code: error?["code"] as? String, param: error?["param"] as? String,
        message: message, requestID: requestID(in: payload, error: error, message: message))
    case "response.incomplete":
      let reason = (payload["incomplete_details"] as? [String: Any])?["reason"] as? String
      return .other(
        status: nil, message: "The reply was cut off" + (reason.map { " (\($0))" } ?? "") + ".",
        requestID: nil)
    case "error":
      let message = payload["message"] as? String
      return map(
        status: nil, code: payload["code"] as? String, param: payload["param"] as? String,
        message: message, requestID: requestID(in: payload, error: nil, message: message))
    default:
      return .other(status: nil, message: "The connection ended before ChatGPT finished the reply.", requestID: nil)
    }
  }

  private static func requestID(in json: [String: Any]?, error: [String: Any]?, message: String?) -> String? {
    if let id = (json?["request_id"] as? String) ?? (error?["request_id"] as? String), !id.isEmpty { return id }
    // OpenAI error messages often end "… include the request ID req_abc123 …".
    guard let message, let range = message.range(of: #"req_[A-Za-z0-9]+"#, options: .regularExpression) else {
      return nil
    }
    return String(message[range])
  }
}
