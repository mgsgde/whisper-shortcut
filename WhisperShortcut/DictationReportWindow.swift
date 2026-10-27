import AppKit
import SwiftUI

/// Opens the "Report a Problem with Your Last Dictation" window.
///
/// The plain Send Feedback entries only know the app and macOS version, so a report about a bad
/// dictation started with a round-trip ("which model? which version? what exactly came out?").
/// This window starts from the dictation itself: the pasted text and the facts the app recorded
/// for it (`DictationReport`). The user can edit or delete any of it, and nothing leaves the Mac
/// until they press send in WhatsApp or Mail.
final class DictationReportWindowController: NSObject, NSWindowDelegate {

  static let shared = DictationReportWindowController()

  private var window: NSWindow?

  /// One window at a time: a second click brings the open one forward instead of stacking a
  /// copy whose text the user has not edited.
  func show(details: String) {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = String(localized: "Report a Problem with a Dictation")
    window.contentView = NSHostingView(rootView: DictationReportView(
      details: details,
      onSend: { [weak self] channel, context in self?.send(channel, context: context) },
      onCancel: { [weak self] in self?.close() }))
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    DebugLogger.log("DICTATION-REPORT: Opened report window (\(details.count) chars)")
  }

  private func send(_ channel: FeedbackLinks.Channel, context: String) {
    // `wa.me` and `mailto:` carry the text in the URL, and an over-long one is dropped silently
    // by some clients instead of failing — clamp it so the report at least arrives.
    let limit = channel == .whatsApp ? 3_000 : 6_000
    if FeedbackLinks.open(channel, context: FeedbackLinks.truncated(context, limit: limit)) {
      DebugLogger.log("DICTATION-REPORT: Opened \(channel.rawValue) with the report")
      close()
    }
  }

  private func close() {
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
  }
}

/// The report: a short "what went wrong" in the user's words above the editable details.
struct DictationReportView: View {
  @State private var problem = ""
  @State private var details: String
  @State private var copied = false
  let onSend: (_ channel: FeedbackLinks.Channel, _ context: String) -> Void
  let onCancel: () -> Void

  init(
    details: String,
    onSend: @escaping (_ channel: FeedbackLinks.Channel, _ context: String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self._details = State(initialValue: details)
    self.onSend = onSend
    self.onCancel = onCancel
  }

  /// What every channel sends: the user's sentence first, because it is what the developer reads
  /// first, then the recorded details.
  private var context: String {
    let note = problem.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = details.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !note.isEmpty else { return body }
    return "What went wrong: \(note)\n\n\(body)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Report a Problem with Your Last Dictation")
          .font(.headline)
        Text(
          "The developer gets the text and the details below, so you don't have to look up "
            + "the version or model. Nothing is sent until you press send in WhatsApp or Mail."
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("What went wrong?")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        TextField(
          "For example: a word I didn't say was added at the end", text: $problem, axis: .vertical
        )
        .lineLimit(2...4)
        .textFieldStyle(.roundedBorder)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Details (editable)")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        TextEditor(text: $details)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(4)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
          .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
          .frame(minHeight: 220)
      }

      // The details hold what was dictated; in a practice that can be a patient's name.
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "hand.raised.fill")
          .foregroundColor(.secondary)
        Text("Contains your dictated text. Remove names or anything else private before you send it.")
          .font(.callout)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 10) {
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.cancelAction)
          .pointerCursorOnHover()

        Spacer()

        Button(copied ? "Copied" : "Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(FeedbackLinks.messageBody(context: context), forType: .string)
          copied = true
        }
        .pointerCursorOnHover()

        Button("Send by Email") { onSend(.email, context) }
          .pointerCursorOnHover()

        // No default-action shortcut: Return in the "what went wrong" field must not send.
        Button("Send via WhatsApp") { onSend(.whatsApp, context) }
          .buttonStyle(.borderedProminent)
          .pointerCursorOnHover()
      }
    }
    .padding(20)
    .frame(minWidth: 560, minHeight: 520)
    .onChange(of: details) { copied = false }
    .onChange(of: problem) { copied = false }
  }
}
