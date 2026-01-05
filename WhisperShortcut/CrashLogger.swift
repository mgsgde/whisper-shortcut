//
//  CrashLogger.swift
//  WhisperShortcut
//
//  User-accessible crash/error logging for debugging.
//  Logs are written to Library/Logs/WhisperShortcut/
//  Note: In sandboxed apps, this resolves to the container path:
//  ~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Logs/WhisperShortcut/
//

import Foundation

/// Logs errors to a user-accessible location for debugging.
/// Uses FileManager's standard API (consistent with ModelManager).
/// In sandboxed apps, logs are written to the container's Library/Logs directory.
class CrashLogger {
    static let shared = CrashLogger()

    private let logDirectory: URL
    private let dateFormatter: DateFormatter

    init() {
        // Use FileManager's standard API to get the Library directory (consistent with ModelManager)
        // In sandboxed apps, this returns the container's Library directory
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        logDirectory = libraryDir
            .appendingPathComponent("Logs/WhisperShortcut")

        // Create log directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    }

    // MARK: - Public API

    /// Log an error to file with context information.
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - context: Description of where/when the error occurred
    ///   - state: Current app state (optional)
    func logError(_ error: Error, context: String, state: AppState? = nil) {
        let timestamp = dateFormatter.string(from: Date())
        let filename = "error_\(timestamp).log"
        let fileURL = logDirectory.appendingPathComponent(filename)

        let content = """
        WhisperShortcut Error Log
        =========================
        Timestamp: \(timestamp)
        Context: \(context)
        App State: \(state?.description ?? "unknown")

        Error: \(error.localizedDescription)

        Full Error:
        \(String(describing: error))

        ---
        Logs location: \(logDirectory.path)
        To view logs: open \(logDirectory.path)
        """

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            DebugLogger.logError("Error logged to: \(fileURL.path)")
        } catch {
            DebugLogger.logError("Failed to write error log: \(error)")
        }
    }

    /// Log a crash-level error (more detailed info).
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - context: Description of where/when the error occurred
    ///   - additionalInfo: Any additional debugging info
    func logCrash(_ error: Error, context: String, additionalInfo: [String: Any]? = nil) {
        let timestamp = dateFormatter.string(from: Date())
        let filename = "crash_\(timestamp).log"
        let fileURL = logDirectory.appendingPathComponent(filename)

        var content = """
        WhisperShortcut Crash Log
        =========================
        Timestamp: \(timestamp)
        Context: \(context)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")

        Error: \(error.localizedDescription)

        Full Error:
        \(String(describing: error))
        """

        if let additionalInfo = additionalInfo {
            content += "\n\nAdditional Info:\n"
            for (key, value) in additionalInfo {
                content += "  \(key): \(value)\n"
            }
        }

        content += """

        ---
        Logs location: \(logDirectory.path)
        To view logs: open \(logDirectory.path)
        """

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            DebugLogger.logError("Crash logged to: \(fileURL.path)")
        } catch {
            DebugLogger.logError("Failed to write crash log: \(error)")
        }
    }

    /// Get path to log directory for user reference.
    var logDirectoryPath: String {
        return logDirectory.path
    }

    /// Clean up old logs (keeps last 50 logs).
    func cleanupOldLogs() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: logDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )

            // Sort by creation date, oldest first
            let sortedFiles = files.sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 < date2
            }

            // Keep only last 50 logs
            let maxLogs = 50
            if sortedFiles.count > maxLogs {
                let toDelete = sortedFiles.prefix(sortedFiles.count - maxLogs)
                for fileURL in toDelete {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                DebugLogger.logDebug("Cleaned up \(toDelete.count) old log files")
            }
        } catch {
            DebugLogger.logError("Failed to cleanup old logs: \(error)")
        }
    }
}
