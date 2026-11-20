import AppKit

/// Hands a report file to Apple Mail, or shows it selected in Finder when Mail cannot take it.
enum ReportSender {
  /// AppKit drops the compose window if the service is released as soon as `perform` returns.
  @MainActor private static var composeService: NSSharingService?

  /// Apple Mail compose with recipient FeedbackLinks' support address, subject = the same localized
  /// subject FeedbackLinks uses for mailto, body, and the file attached. Returns false when the
  /// service is unavailable or cannot perform (e.g. no Mail account), so the caller can fall back.
  @MainActor static func composeEmail(body: String, attachment: URL) -> Bool {
    guard let service = NSSharingService(named: .composeEmail) else {
      DebugLogger.log("DICTATION-REPORT: Mail compose service is unavailable")
      return false
    }
    service.recipients = [FeedbackLinks.supportEmail]
    service.subject = FeedbackLinks.emailSubject
    let items: [Any] = [body, attachment]
    guard service.canPerform(withItems: items) else {
      DebugLogger.log("DICTATION-REPORT: Mail cannot compose with the report file")
      return false
    }
    composeService = service
    service.perform(withItems: items)
    return true
  }

  @MainActor static func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}
