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
  
  // MARK: - File Logging
  private static let fileLogger = FileLogger.shared
  
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .default)
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .error)
  }
  
  /// Logs an error with context information (replaces CrashLogger.logError)
  /// - Parameters:
  ///   - error: The error that occurred
  ///   - context: Description of where/when the error occurred
  ///   - state: Current app state (optional)
  ///   - file: The file name (automatically provided)
  ///   - function: The function name (automatically provided)
  ///   - line: The line number (automatically provided)
  static func logError(
    _ error: Error,
    context: String,
    state: AppState? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let stateDescription = state?.description ?? "unknown"
    
    // Log to os_log
    let osLogMessage = "❌ [\(fileName):\(line)] \(function): \(context) - \(error.localizedDescription)"
    os_log(.error, log: errorLog, "%{public}@", osLogMessage)
    
    // Log detailed error to file
    let fileMessage = """
    Error: \(error.localizedDescription)
    Context: \(context)
    App State: \(stateDescription)
    Full Error: \(String(describing: error))
    """
    fileLogger.log(message: fileMessage, level: .error, context: context, state: stateDescription)
  }
  
  /// Logs a crash-level error with additional info (replaces CrashLogger.logCrash)
  /// - Parameters:
  ///   - error: The error that occurred
  ///   - context: Description of where/when the error occurred
  ///   - additionalInfo: Any additional debugging info
  ///   - file: The file name (automatically provided)
  ///   - function: The function name (automatically provided)
  ///   - line: The line number (automatically provided)
  static func logCrash(
    _ error: Error,
    context: String,
    additionalInfo: [String: Any]? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    
    // Log to os_log
    let osLogMessage = "❌ [\(fileName):\(line)] \(function): CRASH - \(context) - \(error.localizedDescription)"
    os_log(.error, log: errorLog, "%{public}@", osLogMessage)
    
    // Log detailed crash info to file
    var fileMessage = """
    CRASH LOG
    =========
    Context: \(context)
    App Version: \(appVersion)
    Build: \(build)
    Error: \(error.localizedDescription)
    Full Error: \(String(describing: error))
    """
    
    if let additionalInfo = additionalInfo {
      fileMessage += "\n\nAdditional Info:\n"
      for (key, value) in additionalInfo {
        fileMessage += "  \(key): \(value)\n"
      }
    }
    
    fileLogger.log(message: fileMessage, level: .error, context: context, state: "crash")
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .default)
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .default)
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .default)
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .default)
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .default)
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .warning)
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .default)
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .debug)
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
    
    // Also log to file
    fileLogger.log(message: logMessage, level: .default)
  }
  
}

// MARK: - File Logger
/// Private file logger for writing logs to daily files
private class FileLogger {
  static let shared = FileLogger()
  
  private let logDirectory: URL
  private let dateFormatter: DateFormatter
  private let timeFormatter: DateFormatter
  private var fileHandles: [String: FileHandle] = [:] // Key: "2026-01-05"
  private let fileQueue = DispatchQueue(label: "com.whispershortcut.filelogger", qos: .utility)
  private static let logRetentionDays = 7
  private var currentDate: String?
  
  fileprivate enum LogLevel: String {
    case `default` = "INFO"
    case error = "ERROR"
    case warning = "WARN"
    case debug = "DEBUG"
  }
  
  init() {
    // Use FileManager's standard API to get the Library directory (consistent with CrashLogger)
    // In sandboxed apps, this returns the container's Library directory
    let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    logDirectory = libraryDir.appendingPathComponent("Logs/WhisperShortcut")
    
    // Create log directory if it doesn't exist
    try? FileManager.default.createDirectory(
      at: logDirectory,
      withIntermediateDirectories: true
    )
    
    // Date formatters
    dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    
    timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm:ss.SSS"
    
    // Cleanup old logs on init (only once at app start)
    cleanupOldLogs()
  }
  
  fileprivate func log(message: String, level: LogLevel, context: String? = nil, state: String? = nil) {
    fileQueue.async { [weak self] in
      guard let self = self else { return }
      
      let today = self.dateFormatter.string(from: Date())
      let timestamp = self.timeFormatter.string(from: Date())
      
      // Check if we need to switch to a new day
      if let currentDate = self.currentDate, currentDate != today {
        // Day changed - close old handles
        self.closeAllHandles()
        self.currentDate = today
      } else if self.currentDate == nil {
        self.currentDate = today
      }
      
      // Get or create file handle for today
      guard let fileHandle = self.getFileHandle(for: today) else {
        // Failed to get file handle - log error but don't crash
        os_log(.error, log: OSLog(subsystem: "com.magnusgoedde.whispershortcut", category: "FileLogger"), "Failed to get file handle for date: %{public}@", today)
        return
      }
      
      // Format log line
      var logLine = "[\(timestamp)] [\(level.rawValue)] \(message)"
      if let context = context {
        logLine += " | Context: \(context)"
      }
      if let state = state {
        logLine += " | State: \(state)"
      }
      logLine += "\n"
      
      // Write to file (thread-safe, already on fileQueue)
      if let data = logLine.data(using: .utf8) {
        fileHandle.write(data)
        fileHandle.synchronizeFile()
      }
    }
  }
  
  private func getFileHandle(for date: String) -> FileHandle? {
    // Check if handle already exists for this date
    if let existingHandle = fileHandles[date] {
      return existingHandle
    }
    
    // Create new file handle for this date
    let logFile = logDirectory.appendingPathComponent("app_\(date).log")
    
    // Create file if it doesn't exist
    if !FileManager.default.fileExists(atPath: logFile.path) {
      FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: nil)
    }
    
    // Open file handle for appending
    guard let fileHandle = try? FileHandle(forWritingTo: logFile) else {
      os_log(.error, log: OSLog(subsystem: "com.magnusgoedde.whispershortcut", category: "FileLogger"), "Failed to open file handle for: app_%{public}@.log", date)
      return nil
    }
    
    // Seek to end of file
    fileHandle.seekToEndOfFile()
    
    // Store handle
    fileHandles[date] = fileHandle
    
    return fileHandle
  }
  
  private func closeAllHandles() {
    for (_, handle) in fileHandles {
      handle.closeFile()
    }
    fileHandles.removeAll()
  }
  
  private func cleanupOldLogs() {
    fileQueue.async { [weak self] in
      guard let self = self else { return }
      
      do {
        let files = try FileManager.default.contentsOfDirectory(
          at: self.logDirectory,
          includingPropertiesForKeys: [.nameKey],
          options: .skipsHiddenFiles
        )
        
        let today = Date()
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -FileLogger.logRetentionDays, to: today) ?? today
        
        for file in files {
          // Only process app_*.log files
          let filename = file.lastPathComponent
          guard filename.hasPrefix("app_") && filename.hasSuffix(".log") else {
            continue
          }
          
          // Extract date from filename (app_YYYY-MM-DD.log)
          let dateString = String(filename.dropFirst(4).dropLast(4)) // Remove "app_" and ".log"
          
          if let fileDate = self.dateFormatter.date(from: dateString) {
            // Delete if older than retention period
            if fileDate < cutoffDate {
              try? FileManager.default.removeItem(at: file)
            }
          }
        }
      } catch {
        // Log error but don't crash - cleanup failures shouldn't break the app
        os_log(.error, log: OSLog(subsystem: "com.magnusgoedde.whispershortcut", category: "FileLogger"), "Failed to cleanup old logs: %{public}@", error.localizedDescription)
      }
    }
  }
  
  deinit {
    // Close all file handles on deinit
    fileQueue.sync {
      closeAllHandles()
    }
  }
}