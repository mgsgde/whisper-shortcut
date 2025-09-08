import Foundation

/// Debug logging utility for development and debugging
/// All NSLog statements should use this utility to ensure they're only active in debug builds
struct DebugLogger {
  
  /// Logs a debug message only in debug builds
  /// - Parameters:
  ///   - message: The message to log
  ///   - file: The file name (automatically provided)
  ///   - function: The function name (automatically provided)
  ///   - line: The line number (automatically provided)
  static func log(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    #if DEBUG
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    NSLog("[\(fileName):\(line)] \(function): \(message)")
    #endif
  }
  
  /// Logs an error message only in debug builds
  /// - Parameters:
  ///   - message: The error message to log
  ///   - file: The file name (automatically provided)
  ///   - function: The function name (automatically provided)
  ///   - line: The line number (automatically provided)
  static func logError(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    #if DEBUG
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    NSLog("❌ [\(fileName):\(line)] \(function): \(message)")
    #endif
  }
  
  /// Logs a success message only in debug builds
  /// - Parameters:
  ///   - message: The success message to log
  ///   - file: The file name (automatically provided)
  ///   - function: The function name (automatically provided)
  ///   - line: The line number (automatically provided)
  static func logSuccess(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    #if DEBUG
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    NSLog("✅ [\(fileName):\(line)] \(function): \(message)")
    #endif
  }
  
  /// Logs a warning message only in debug builds
  /// - Parameters:
  ///   - message: The warning message to log
  ///   - file: The file name (automatically provided)
  ///   - function: The function name (automatically provided)
  ///   - line: The line number (automatically provided)
  static func logWarning(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    #if DEBUG
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    NSLog("⚠️ [\(fileName):\(line)] \(function): \(message)")
    #endif
  }
  
  /// Logs an info message only in debug builds
  /// - Parameters:
  ///   - message: The info message to log
  ///   - file: The file name (automatically provided)
  ///   - function: The function name (automatically provided)
  ///   - line: The line number (automatically provided)
  static func logInfo(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    #if DEBUG
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    NSLog("ℹ️ [\(fileName):\(line)] \(function): \(message)")
    #endif
  }
}





