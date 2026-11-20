import AppKit

/// Hands a report file to Apple Mail, or shows it selected in Finder when Mail cannot take it.
enum ReportSender {
  /// AppKit drops the compose window if the service is released as soon as `perform` returns.
  @MainActor private static var composeService: NSSharingService?
  /// Same for the share picker: it must outlive `show`.
  @MainActor private static var sharePicker: NSSharingServicePicker?

  /// Apple Mail is the only handler whose compose service can attach the report file.
  /// Anything else (a browser, Outlook, nothing) goes straight to `mailto:` plus Finder.
  static func prefersAppleMail(mailtoHandlerBundleID: String?) -> Bool {
    mailtoHandlerBundleID == "com.apple.mail"
  }

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

  /// Puts the file itself on the clipboard, as Finder's Copy does: ⌘V in a WhatsApp chat or a
  /// mail attaches it, which is easier to find than dragging it out of a Finder window.
  @MainActor static func copyFileToClipboard(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([url as NSURL])
  }

  @MainActor static func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  /// AirDrop, Messages, Mail, Save to Files, and whatever else is installed. Anchored at the
  /// bottom-right of `view`.
  @MainActor static func share(_ url: URL, relativeTo view: NSView) {
    let picker = NSSharingServicePicker(items: [url])
    sharePicker = picker
    let bounds = view.bounds
    let anchor = NSRect(x: bounds.maxX, y: bounds.minY, width: 0, height: 0)
    picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
  }
}
