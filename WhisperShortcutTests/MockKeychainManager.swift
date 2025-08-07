import Foundation

@testable import WhisperShortcut

class MockKeychainManager: KeychainManaging {
  private var storedAPIKey: String?

  func saveAPIKey(_ apiKey: String) -> Bool {
    storedAPIKey = apiKey
    return true
  }

  func getAPIKey() -> String? {
    return storedAPIKey
  }

  func deleteAPIKey() -> Bool {
    storedAPIKey = nil
    return true
  }

  func hasAPIKey() -> Bool {
    return storedAPIKey != nil
  }

  // Test helper methods
  func clear() {
    storedAPIKey = nil
  }
}
