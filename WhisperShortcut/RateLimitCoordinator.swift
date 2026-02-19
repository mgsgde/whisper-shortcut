//
//  RateLimitCoordinator.swift
//  WhisperShortcut
//
//  Shared actor for coordinating rate limiting across parallel API requests.
//

import Foundation

/// Actor to coordinate rate limiting across all parallel API requests.
/// When one request hits a 429, all requests pause together.
actor RateLimitCoordinator {
    /// Logging prefix for debug output
    private let logPrefix: String

    /// Time until which all requests should wait
    private var pauseUntil: Date = .distantPast

    /// Number of consecutive rate limit errors (for adaptive backoff)
    private var consecutiveRateLimits: Int = 0

    /// Whether we've already shown a notification for the current wait period
    private var notificationShown: Bool = false

    /// Initialize with a custom log prefix
    /// - Parameter logPrefix: Prefix for debug log messages (e.g., "RATE-LIMIT" or "TTS-RATE-LIMIT")
    init(logPrefix: String = "RATE-LIMIT-COORDINATOR") {
        self.logPrefix = logPrefix
    }

    /// Wait if we're currently in a rate-limited period
    func waitIfNeeded() async {
        let now = Date()
        if pauseUntil > now {
            let waitTime = pauseUntil.timeIntervalSince(now)
            DebugLogger.log("\(logPrefix): Waiting \(String(format: "%.1f", waitTime))s before next request")

            // Show notification if not already shown for this wait period
            if !notificationShown {
                notificationShown = true
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .rateLimitWaiting,
                        object: nil,
                        userInfo: ["waitTime": waitTime]
                    )
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))

            // Dismiss notification after wait (only once)
            if notificationShown {
                notificationShown = false
                await MainActor.run {
                    NotificationCenter.default.post(name: .rateLimitResolved, object: nil)
                }
            }
        }
    }

    /// Report a rate limit error with optional retry delay from API
    func reportRateLimit(retryAfter: TimeInterval?) {
        consecutiveRateLimits += 1

        // Use API-provided delay, or calculate exponential backoff
        let delay: TimeInterval
        if let retryAfter = retryAfter {
            // Add small buffer to API-provided delay
            delay = retryAfter + 2.0
            DebugLogger.log("\(logPrefix): API requested \(retryAfter)s delay, using \(delay)s")
        } else {
            // Exponential backoff: 30s, 60s, 120s, capped at 120s
            delay = min(30.0 * pow(2.0, Double(consecutiveRateLimits - 1)), 120.0)
            DebugLogger.log("\(logPrefix): No API delay, using exponential backoff: \(delay)s")
        }

        let newPauseUntil = Date().addingTimeInterval(delay)
        if newPauseUntil > pauseUntil {
            pauseUntil = newPauseUntil
            notificationShown = false  // Reset so next waitIfNeeded shows notification
            DebugLogger.log("\(logPrefix): All requests paused until \(pauseUntil)")
        }
    }

    /// Report a successful request (resets consecutive counter)
    func reportSuccess() {
        if consecutiveRateLimits > 0 {
            DebugLogger.log("\(logPrefix): Request succeeded, resetting rate limit counter")
            consecutiveRateLimits = 0
        }
    }
}
