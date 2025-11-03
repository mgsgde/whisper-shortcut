import Foundation
import StoreKit
import AppKit

/// Service to manage in-app review prompts based on successful operations
class ReviewPrompter {
  
  // MARK: - Constants
  private enum Constants {
    static let successfulOperationsCountKey = "successfulOperationsCount"
    static let operationThreshold = 10
  }
  
  // MARK: - Singleton
  static let shared = ReviewPrompter()
  
  private init() {}
  
  // MARK: - Counter Management
  
  /// Record a successful operation and check if review prompt should be shown
  /// - Parameter window: The window to present the review prompt on (typically status item button window)
  func recordSuccessfulOperation(window: NSWindow?) {
    let currentCount = UserDefaults.standard.integer(forKey: Constants.successfulOperationsCountKey)
    let newCount = currentCount + 1
    
    UserDefaults.standard.set(newCount, forKey: Constants.successfulOperationsCountKey)
    
    DebugLogger.log("REVIEW: Successful operation recorded. Count: \(newCount)/\(Constants.operationThreshold)")
    
    // Check if threshold is reached
    if newCount >= Constants.operationThreshold {
      DebugLogger.log("REVIEW: Threshold reached! Triggering review prompt...")
      showReviewPrompt(window: window)
      
      // Reset counter after showing prompt
      resetCounter()
    }
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
    UserDefaults.standard.set(0, forKey: Constants.successfulOperationsCountKey)
    DebugLogger.log("REVIEW: Counter reset to 0")
  }
  
  /// Get the current count (for debugging/testing purposes)
  func getCurrentCount() -> Int {
    return UserDefaults.standard.integer(forKey: Constants.successfulOperationsCountKey)
  }
  
  /// Manually reset the counter (for testing purposes)
  func manualReset() {
    resetCounter()
    DebugLogger.log("REVIEW: Manual counter reset performed")
  }
}

