//
//  BackendAPIClient.swift
//  WhisperShortcut
//
//  Client for backend API: usage reporting (POST /v1/usage), config (GET /v1/config/subscription-models).
//  Uses the same base URL as the proxy (proxyAPIBaseURL). Auth: Bearer Google ID token for usage; config is unauthenticated.
//

import Foundation

#if SUBSCRIPTION_ENABLED
/// Response from GET /v1/config/subscription-models. Model IDs used by the proxy for subscription users.
struct SubscriptionModelsConfig: Codable {
  var transcription: String?
  var prompt_mode: String?
  var smart_improvement: String?
  var gemini_chat: String?
  var meeting_summary: String?
  var tts: String?
  var default_gemini: String?
}

/// Request body for POST /v1/usage
struct UsageRequest: Codable {
  let amount_cent: Int
  let product: String?
}

/// Response from GET /v1/subscription. Indicates whether the user has an active subscription.
struct SubscriptionStatusResponse: Codable {
  let active: Bool
}
#endif

/// Client for Whisper backend API (usage). Non-blocking; errors are logged, not thrown to caller.
enum BackendAPIClient {
  private static let session: URLSession = {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 15
    return URLSession(configuration: c)
  }()

  /// Base URL for the backend (no trailing slash). Set by the app (production whisper-api).
  static func baseURL() -> String {
    SettingsDefaults.proxyAPIBaseURL
  }

  #if SUBSCRIPTION_ENABLED
  /// Reports usage (deducts balance). Fire-and-forget; logs errors. Use from background if needed.
  static func reportUsage(amountCent: Int, product: String?, idTokenProvider: @escaping () async -> String?) {
    Task {
      let base = baseURL()
      guard let url = URL(string: base + "/v1/usage") else {
        DebugLogger.logNetwork("BACKEND-API: Invalid base URL; skip usage report")
        return
      }
      guard let token = await idTokenProvider() else {
        DebugLogger.logNetwork("BACKEND-API: No ID token; skip usage report")
        return
      }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let body = UsageRequest(amount_cent: amountCent, product: product)
      do {
        request.httpBody = try JSONEncoder().encode(body)
      } catch {
        DebugLogger.logNetwork("BACKEND-API: Encode usage request failed: \(error.localizedDescription)")
        return
      }
      do {
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
          DebugLogger.logNetwork("BACKEND-API: POST /v1/usage returned \(http.statusCode)")
        }
      } catch {
        DebugLogger.logNetwork("BACKEND-API: Usage report failed: \(error.localizedDescription)")
      }
    }
  }

  /// Fetches subscription models from GET /v1/config/subscription-models. No auth. Returns nil on failure.
  static func fetchSubscriptionModels() async -> SubscriptionModelsConfig? {
    let base = baseURL()
    guard let url = URL(string: base + "/v1/config/subscription-models") else {
      DebugLogger.logNetwork("BACKEND-API: Invalid base URL; skip subscription-models fetch")
      return nil
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        DebugLogger.logNetwork("BACKEND-API: GET /v1/config/subscription-models returned \(code)")
        return nil
      }
      let decoder = JSONDecoder()
      let config = try decoder.decode(SubscriptionModelsConfig.self, from: data)
      DebugLogger.logNetwork("BACKEND-API: Subscription models config loaded")
      return config
    } catch {
      DebugLogger.logNetwork("BACKEND-API: Subscription models fetch failed: \(error.localizedDescription)")
      return nil
    }
  }

  /// Fetches subscription status from GET /v1/subscription. Requires Bearer token (signed-in user).
  /// Returns true if the user has an active subscription, false if not, nil on network/auth failure.
  static func fetchSubscriptionStatus(idTokenProvider: @escaping () async -> String?) async -> Bool? {
    let base = baseURL()
    guard let url = URL(string: base + "/v1/subscription") else {
      DebugLogger.logNetwork("BACKEND-API: Invalid base URL; skip subscription status fetch")
      return nil
    }
    guard let token = await idTokenProvider() else {
      DebugLogger.logNetwork("BACKEND-API: No ID token; skip subscription status fetch")
      return nil
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { return nil }
      guard http.statusCode == 200 else {
        DebugLogger.logNetwork("BACKEND-API: GET /v1/subscription returned \(http.statusCode)")
        return nil
      }
      let decoder = JSONDecoder()
      let status = try decoder.decode(SubscriptionStatusResponse.self, from: data)
      return status.active
    } catch {
      DebugLogger.logNetwork("BACKEND-API: Subscription status fetch failed: \(error.localizedDescription)")
      return nil
    }
  }
  #endif
}
