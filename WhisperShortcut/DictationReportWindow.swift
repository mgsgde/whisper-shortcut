import AppKit
import SwiftUI

/// Opens the "Report a Problem" window for the newest result.
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
  func show(candidates: [ResultReport.Candidate]) {
    guard let newest = candidates.first else {
      DebugLogger.logWarning("DICTATION-REPORT: Open requested with no candidates")
      return
    }
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = String(localized: "Report a Problem")
    window.contentView = NSHostingView(rootView: DictationReportView(
      candidates: candidates,
      onSend: { [weak self] channel, context in self?.send(channel, context: context) },
      onCancel: { [weak self] in self?.close() }))
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    DebugLogger.log(
      "DICTATION-REPORT: Opened report window on \(newest.kind.rawValue) (\(candidates.count) results, \(newest.details.count) chars)")
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
///
/// It opens on the newest result, whichever feature produced it, because that is almost always
/// the one the user means: they just saw it go wrong. The others (at most one per feature) sit
/// behind "Report Something Else" instead of a picker up front, so nobody has to know what the
/// features are called to report the one in front of them.
struct DictationReportView: View {
  let candidates: [ResultReport.Candidate]
  @State private var selected: ResultReport.Kind
  @State private var problem = ""
  /// Edits per result, so switching away and back does not throw away what the user removed.
  @State private var editedDetails: [ResultReport.Kind: String] = [:]
  @State private var copied = false
  let onSend: (_ channel: FeedbackLinks.Channel, _ context: String) -> Void
  let onCancel: () -> Void

  init(
    candidates: [ResultReport.Candidate],
    onSend: @escaping (_ channel: FeedbackLinks.Channel, _ context: String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.candidates = candidates
    self._selected = State(initialValue: candidates.first?.kind ?? .dictation)
    self.onSend = onSend
    self.onCancel = onCancel
  }

  private var current: ResultReport.Candidate? {
    candidates.first { $0.kind == selected }
  }

  private var details: Binding<String> {
    Binding(
      get: { editedDetails[selected] ?? current?.details ?? "" },
      set: { editedDetails[selected] = $0 })
  }

  private var others: [ResultReport.Candidate] {
    candidates.filter { $0.kind != selected }
  }

  private var headline: LocalizedStringKey {
    switch selected {
    case .dictation: return "Report a Problem with Your Last Dictation"
    case .prompt: return "Report a Problem with Your Last Prompt Answer"
    case .readAloud: return "Report a Problem with the Last Read Aloud"
    }
  }

  private var placeholder: LocalizedStringKey {
    switch selected {
    case .dictation: return "For example: a word I didn't say was added at the end"
    case .prompt: return "For example: the answer ignored my instruction"
    case .readAloud: return "For example: a word was pronounced wrong"
    }
  }

  private var privacyNote: LocalizedStringKey {
    switch selected {
    case .dictation:
      return "Contains your dictated text. Remove names or anything else private before you send it."
    case .prompt:
      return "Contains your instruction, part of the selected text and the answer. Remove names or anything else private before you send it."
    case .readAloud:
      return "Contains the text that was read aloud. Remove names or anything else private before you send it."
    }
  }

  private static func kindLabel(_ kind: ResultReport.Kind) -> String {
    switch kind {
    case .dictation: return String(localized: "Dictation")
    case .prompt: return String(localized: "Prompt Answer")
    case .readAloud: return String(localized: "Read Aloud")
    }
  }

  /// "Prompt Answer · 08:02 · Fasse das kurz zusammen…": what it was, when, and how it started,
  /// which is enough to recognise it without opening it.
  private static func menuTitle(_ candidate: ResultReport.Candidate) -> String {
    let time = candidate.ts.formatted(date: .omitted, time: .shortened)
    return "\(kindLabel(candidate.kind)) · \(time) · \(candidate.preview)"
  }

  /// What every channel sends: the user's sentence first, because it is what the developer reads
  /// first, then the recorded details.
  private var context: String {
    let note = problem.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = details.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !note.isEmpty else { return body }
    return "What went wrong: \(note)\n\n\(body)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(headline)
            .font(.headline)
          Spacer()
          if !others.isEmpty {
            Menu("Report Something Else") {
              ForEach(others, id: \.kind) { candidate in
                Button(Self.menuTitle(candidate)) {
                  selected = candidate.kind
                  copied = false
                  DebugLogger.log("DICTATION-REPORT: Switched to \(candidate.kind.rawValue)")
                }
              }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .pointerCursorOnHover()
          }
        }
        Text("The developer gets the text and the details below, so you don't have to look up the version or model. Nothing is sent until you press send in WhatsApp or Mail.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("What went wrong?")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        TextField(placeholder, text: $problem, axis: .vertical)
        .lineLimit(2...4)
        .textFieldStyle(.roundedBorder)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Details (editable)")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        TextEditor(text: details)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(4)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
          .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
          .frame(minHeight: 220)
      }

      // The details hold what was dictated, selected or read; in a practice that can be a
      // patient's name.
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "hand.raised.fill")
          .foregroundColor(.secondary)
        Text(privacyNote)
          .font(.callout)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 10) {
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.cancelAction)
          .pointerCursorOnHover()

        Spacer()

        Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
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
    .onChange(of: editedDetails) { copied = false }
    .onChange(of: problem) { copied = false }
  }
}
