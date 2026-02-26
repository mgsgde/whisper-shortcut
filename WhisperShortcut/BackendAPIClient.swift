//
//  BackendAPIClient.swift
//  WhisperShortcut
//
//  Client for backend API: usage reporting (POST /v1/usage).
//  Uses the same base URL as the proxy (proxyAPIBaseURL). Auth: Bearer Google ID token.
//

import Foundation

/// Request body for POST /v1/usage
struct UsageRequest: Codable {
  let amount_cent: Int
  let product: String?
}

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
}
