import Foundation

/// True when this process is the XCTest host (unit tests run inside the app bundle).
enum TestHost {
  static let isActive: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["XCTestConfigurationFilePath"] != nil
      || env["XCTestBundlePath"] != nil
      || NSClassFromString("XCTestCase") != nil
  }()
}
