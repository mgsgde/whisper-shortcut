import Foundation
import StoreKit
import AppKit

/// Service to manage in-app review prompts based on successful operations
class ReviewPrompter {
  
  // MARK: - Constants
  private enum Constants {
    static let operationThreshold = 10
    static let minimumDaysBetweenPrompts = 30.0 // Only prompt once every 30 days minimum
  }
  
  // MARK: - Singleton
  static let shared = ReviewPrompter()
  
  private init() {}
  
  // MARK: - Counter Management
  
  /// Record a successful operation and check if review prompt should be shown
  /// - Parameter window: The window to present the review prompt on (typically status item button window)
  func recordSuccessfulOperation(window: NSWindow?) {
    let currentCount = UserDefaults.standard.integer(forKey: UserDefaultsKeys.successfulOperationsCount)
    let newCount = currentCount + 1
    
    UserDefaults.standard.set(newCount, forKey: UserDefaultsKeys.successfulOperationsCount)
    
    DebugLogger.log("REVIEW: Successful operation recorded. Count: \(newCount)/\(Constants.operationThreshold)")
    
    // Check if threshold is reached
    if newCount >= Constants.operationThreshold {
      // Check if enough time has passed since last prompt
      if shouldShowPrompt() {
        DebugLogger.log("REVIEW: Threshold reached and time condition met! Triggering review prompt...")
        showReviewPrompt(window: window)
        
        // Reset counter and update last prompt date
        resetCounter()
        updateLastPromptDate()
      } else {
        DebugLogger.log("REVIEW: Threshold reached but not enough time has passed since last prompt. Skipping.")
      }
    }
  }
  
  /// Check if enough time has passed since the last review prompt
  /// - Returns: True if prompt should be shown, false otherwise
  private func shouldShowPrompt() -> Bool {
    guard let lastPromptDate = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastReviewPromptDate) as? Date else {
      // No previous prompt date, allow prompt
      return true
    }
    
    let daysSinceLastPrompt = Date().timeIntervalSince(lastPromptDate) / (60 * 60 * 24)
    
    DebugLogger.log("REVIEW: Days since last prompt: \(String(format: "%.1f", daysSinceLastPrompt))")
    
    return daysSinceLastPrompt >= Constants.minimumDaysBetweenPrompts
  }
  
  /// Update the last prompt date to now
  private func updateLastPromptDate() {
    UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastReviewPromptDate)
    DebugLogger.log("REVIEW: Last prompt date updated to now")
  }
  
  /// Show the native macOS review prompt
  /// - Parameter window: The window to present the review prompt on (unused on macOS, kept for API consistency)
  private func showReviewPrompt(window: NSWindow?) {
    // Request review on main thread
    // Note: On macOS, SKStoreReviewController.requestReview() doesn't require a window scene
    DispatchQueue.main.async {
      SKStoreReviewController.requestReview()
      DebugLogger.log("REVIEW: Review prompt displayed")
    }
  }
  
  /// Reset the counter after showing a review prompt
  private func resetCounter() {
    UserDefaults.standard.set(0, forKey: UserDefaultsKeys.successfulOperationsCount)
    DebugLogger.log("REVIEW: Counter reset to 0")
  }
}

