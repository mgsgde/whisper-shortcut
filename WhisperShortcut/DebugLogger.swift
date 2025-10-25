import Foundation
import os.log

/// Modern logging utility using Apple's Unified Logging System (os_log)
/// This works with LSUIElement apps and provides structured logging
///
/// # CRITICAL LOGGING LEVEL BEHAVIOR
///
/// ## ❌ Logging Levels That DON'T Work
/// - **`.debug` Level**: `os_log(.debug, ...)` does NOT appear in logs
/// - **`.info` Level**: `os_log(.info, ...)` does NOT appear in logs
/// 
/// This is a known limitation of macOS Unified Logging System.
/// These levels are filtered out by the system and won't be visible
/// in `log stream` or `log show` commands.
///
/// ## ✅ Logging Levels That DO Work
/// - **`.default` Level**: `os_log(.default, ...)` - ✅ WORKS PERFECTLY
/// - **`.error` Level**: `os_log(.error, ...)` - ✅ WORKS PERFECTLY
///
/// ## 🔧 Implementation Strategy
/// All logging methods use `.default` level internally to ensure visibility:
/// - `logDebug()` → uses `.default` (not `.debug`)
/// - `logInfoLevel()` → uses `.default` (not `.info`)
/// - `logError()` → uses `.error` (works correctly)
/// - All other methods → use `.default`
///
/// ## 📋 Available Methods
/// - `log()` - General messages
/// - `logError()` - Error conditions (uses .error level)
/// - `logDebug()` - Debug messages (uses .default level)
/// - `logInfo()` - Info messages (uses .default level)
/// - `logInfoLevel()` - Info messages (uses .default level)
/// - `logWarning()` - Warning messages (uses .default level)
/// - `logSuccess()` - Success messages (uses .default level)
/// - `logUI()` - UI-related messages (uses .default level)
/// - `logAudio()` - Audio-related messages (uses .default level)
/// - `logNetwork()` - Network-related messages (uses .default level)
/// - `logSpeech()` - Speech-related messages (uses .default level)
///
/// ## 🛠️ Usage Examples
/// ```swift
/// // ✅ All of these work and are visible in logs:
/// DebugLogger.log("General message")
/// DebugLogger.logError("Error occurred")
/// DebugLogger.logDebug("Debug information")
/// DebugLogger.logWarning("Warning message")
/// DebugLogger.logSuccess("Success message")
/// ```
///
/// ## 🔍 Viewing Logs
/// ```bash
/// # Stream logs in real-time
/// bash ./scripts/logs.sh
/// 
/// # Filter for specific categories
/// bash ./scripts/logs.sh -f '🎤'  # Speech logs
/// bash ./scripts/logs.sh -f '❌'  # Error logs
/// ```
struct DebugLogger {
  
  // MARK: - Log Categories
  private static let appLog = OSLog(subsystem: "com.magnusgoedde.whispershortcut", category: "App")
  private static let uiLog = OSLog(subsystem: "com.magnusgoedde.whispershortcut", category: "UI")
  private static let audioLog = OSLog(subsystem: "com.magnusgoedde.whispershortcut", category: "Audio")
  private static let networkLog = OSLog(subsystem: "com.magnusgoedde.whispershortcut", category: "Network")
  private static let speechLog = OSLog(subsystem: "com.magnusgoedde.whispershortcut", category: "Speech")
  private static let errorLog = OSLog(subsystem: "com.magnusgoedde.whispershortcut", category: "Error")
  
  // MARK: - Modern os_log Methods
  
  /// Logs a debug message using Apple's Unified Logging System
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
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "[\(fileName):\(line)] \(function): \(message)"
    
    // Modern os_log logging (works with LSUIElement apps)
    os_log(.default, log: appLog, "%{public}@", logMessage)
  }
  
  /// Logs an error message using os_log
  static func logError(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "❌ [\(fileName):\(line)] \(function): \(message)"
    
    os_log(.error, log: errorLog, "%{public}@", logMessage)
  }
  
  /// Logs UI-related messages
  static func logUI(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "🎨 [\(fileName):\(line)] \(function): \(message)"
    
    os_log(.default, log: uiLog, "%{public}@", logMessage)
  }
  
  /// Logs audio-related messages
  static func logAudio(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "🎵 [\(fileName):\(line)] \(function): \(message)"
    
    os_log(.default, log: audioLog, "%{public}@", logMessage)
  }
  
  /// Logs network-related messages
  static func logNetwork(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "🌐 [\(fileName):\(line)] \(function): \(message)"
    
    os_log(.default, log: networkLog, "%{public}@", logMessage)
  }
  
  /// Logs speech-related messages
  static func logSpeech(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "🎤 [\(fileName):\(line)] \(function): \(message)"
    
    os_log(.default, log: speechLog, "%{public}@", logMessage)
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
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "✅ [\(fileName):\(line)] \(function): \(message)"
    
    os_log(.default, log: appLog, "%{public}@", logMessage)
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
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "⚠️ [\(fileName):\(line)] \(function): \(message)"
    
    os_log(.default, log: appLog, "%{public}@", logMessage)
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
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "ℹ️ [\(fileName):\(line)] \(function): \(message)"
    
    os_log(.default, log: appLog, "%{public}@", logMessage)
  }
  
  /// Logs a debug message using .default level (since .debug doesn't show in logs)
  /// 
  /// ⚠️ **IMPORTANT**: This method uses `.default` level instead of `.debug` level
  /// because `os_log(.debug, ...)` does NOT appear in macOS logs due to system filtering.
  /// 
  /// - Parameters:
  ///   - message: The debug message to log
  ///   - file: The file name (automatically provided)
  ///   - function: The function name (automatically provided)
  ///   - line: The line number (automatically provided)
  static func logDebug(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "🔍 [\(fileName):\(line)] \(function): \(message)"
    
    // Use .default instead of .debug since .debug doesn't show in logs
    os_log(.default, log: appLog, "%{public}@", logMessage)
  }
  
  /// Logs an info message using .default level (since .info doesn't show in logs)
  /// 
  /// ⚠️ **IMPORTANT**: This method uses `.default` level instead of `.info` level
  /// because `os_log(.info, ...)` does NOT appear in macOS logs due to system filtering.
  /// 
  /// - Parameters:
  ///   - message: The info message to log
  ///   - file: The file name (automatically provided)
  ///   - function: The function name (automatically provided)
  ///   - line: The line number (automatically provided)
  static func logInfoLevel(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logMessage = "ℹ️ [\(fileName):\(line)] \(function): \(message)"
    
    // Use .default instead of .info since .info doesn't show in logs
    os_log(.default, log: appLog, "%{public}@", logMessage)
  }
}