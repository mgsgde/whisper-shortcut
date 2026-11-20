import AppKit
import SwiftUI

/// Opens the "Report a Problem" window for the newest result.
///
/// The plain Send Feedback entries only know the app and macOS version, so a report about a bad
/// dictation started with a round-trip ("which model? which version? what exactly came out?").
/// This window starts from the dictation itself: the pasted text and the facts the app recorded
/// for it (`DictationReport`). The user can edit or delete any of it, and nothing leaves the Mac
/// until they press send in their mail app. WhatsApp is not offered here: it cannot carry the
/// settings file without the user pasting it, and nobody reports from a Mac through WhatsApp.
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
      onSend: { [weak self] channel, context, attachment in
        self?.send(channel, context: context, attachment: attachment) ?? false
      },
      onShare: { [weak self] context, attachment in
        self?.share(context: context, attachment: attachment)
      },
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

  /// True when the report file was revealed in Finder for the user to drag in: the window then
  /// stays open and says so, because the message alone does not carry the settings.
  private func send(_ channel: FeedbackLinks.Channel, context: String, attachment: String? = nil)
    -> Bool
  {
    // `wa.me` and `mailto:` carry the text in the URL, and an over-long one is dropped silently
    // by some clients instead of failing — clamp it so the report at least arrives.
    let limit = channel == .whatsApp ? 3_000 : 6_000
    let clamped = FeedbackLinks.truncated(context, limit: limit)
    guard let attachment else {
      openClamped(channel, context: clamped)
      return false
    }
    switch channel {
    case .email:
      return sendEmail(clampedContext: clamped, attachment: attachment)
    case .whatsApp, .gitHub:
      openClamped(channel, context: clamped)
      return false
    }
  }

  private func openClamped(_ channel: FeedbackLinks.Channel, context: String) {
    if FeedbackLinks.open(channel, context: context) {
      DebugLogger.log("DICTATION-REPORT: Opened \(channel.rawValue) with the report")
      close()
    }
  }

  /// The file holds the configuration. The message itself stays the clamped dictation text, which
  /// is what Mail can still show when the attachment cannot be added.
  private func sendEmail(clampedContext: String, attachment: String) -> Bool {
    let file: URL
    do {
      file = try ReportAttachment.write(attachment)
    } catch {
      DebugLogger.logWarning(
        "DICTATION-REPORT: Could not write the report file: \(error.logDescription)")
      showSettingsFileAlert()
      return false
    }
    let mailto = URL(string: "mailto:")!
    let handler = NSWorkspace.shared.urlForApplication(toOpen: mailto)
    let handlerBundleID = handler.flatMap { Bundle(url: $0)?.bundleIdentifier }
    if ReportSender.prefersAppleMail(mailtoHandlerBundleID: handlerBundleID) {
      let sent = MainActor.assumeIsolated {
        ReportSender.composeEmail(
          body: FeedbackLinks.messageBody(context: clampedContext), attachment: file)
      }
      if sent {
        DebugLogger.log("DICTATION-REPORT: Opened email with \(file.lastPathComponent) attached")
        close()
        return false
      }
    }
    MainActor.assumeIsolated {
      ReportSender.revealInFinder(file)
      ReportSender.copyFileToClipboard(file)
    }
    let opened = FeedbackLinks.open(
      .email, context: Self.withFileNote(clampedContext, file: file))
    if opened {
      DebugLogger.log("DICTATION-REPORT: Opened mailto and revealed \(file.lastPathComponent)")
    } else {
      DebugLogger.logWarning(
        "DICTATION-REPORT: mailto did not open; revealed \(file.lastPathComponent)")
    }
    return true
  }

  /// The message names the file, so the developer notices when it was not pasted.
  static func withFileNote(_ context: String, file: URL) -> String {
    context + "\n\n" + String(localized: "Settings attached as a file: \(file.lastPathComponent)")
  }

  /// Writes the report file and offers it through the system share picker. The window stays open.
  func share(context: String, attachment: String?) {
    let text = attachment ?? FeedbackLinks.messageBody(context: context)
    let file: URL
    do {
      file = try ReportAttachment.write(text)
    } catch {
      DebugLogger.logWarning(
        "DICTATION-REPORT: Could not write the report file: \(error.logDescription)")
      showSettingsFileAlert()
      return
    }
    guard let view = window?.contentView else {
      DebugLogger.logWarning("DICTATION-REPORT: Share requested but the window has no content view")
      return
    }
    MainActor.assumeIsolated { ReportSender.share(file, relativeTo: view) }
    DebugLogger.log("DICTATION-REPORT: Offered \(file.lastPathComponent) to share")
  }

  /// Settings were requested and the file that would carry them could not be written.
  /// Sending the message alone would drop them without saying so.
  private func showSettingsFileAlert() {
    let alert = NSAlert()
    alert.messageText = String(localized: "The settings file could not be created.")
    alert.informativeText = String(
      localized: "Use Copy instead: it puts everything on the clipboard.")
    alert.addButton(withTitle: String(localized: "OK"))
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
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
/// the one the user means: they just saw it go wrong. The others sit behind "Report Something
/// Else" instead of a picker up front, so nobody has to know what the features are called to
/// report the one in front of them.
struct DictationReportView: View {
  let candidates: [ResultReport.Candidate]
  @State private var selected: String
  @State private var problem = ""
  /// Edits per result, so switching away and back does not throw away what the user removed.
  @State private var editedDetails: [String: String] = [:]
  @State private var copied = false
  /// "Also send my settings". All three start on; see the comment at the checkboxes.
  @State private var includeGlossary = true
  @State private var includePrompts = true
  @State private var includeTemplates = true
  /// Set after an email send that could not attach the file (no Apple Mail); the window stays
  /// open and says how to add it, since the mail does not have it yet.
  @State private var fileOnClipboard = false
  /// Returns true when the report file was revealed in Finder instead of attached.
  let onSend: (_ channel: FeedbackLinks.Channel, _ context: String, _ attachment: String?) -> Bool
  let onShare: (_ context: String, _ attachment: String?) -> Void
  let onCancel: () -> Void

  init(
    candidates: [ResultReport.Candidate],
    onSend: @escaping (_ channel: FeedbackLinks.Channel, _ context: String, _ attachment: String?) -> Bool,
    onShare: @escaping (_ context: String, _ attachment: String?) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.candidates = candidates
    self._selected = State(initialValue: candidates.first?.id ?? "")
    self.onSend = onSend
    self.onShare = onShare
    self.onCancel = onCancel
  }

  private var current: ResultReport.Candidate? {
    candidates.first { $0.id == selected }
  }

  private var kind: ResultReport.Kind { current?.kind ?? .dictation }

  private var details: Binding<String> {
    Binding(
      get: { editedDetails[selected] ?? current?.details ?? "" },
      set: { editedDetails[selected] = $0 })
  }

  private var others: [ResultReport.Candidate] {
    candidates.filter { $0.id != selected }
  }

  private var headline: LocalizedStringKey {
    switch kind {
    case .dictation: return "Report a Problem with Your Last Dictation"
    case .prompt: return "Report a Problem with Your Last Prompt Answer"
    case .readAloud: return "Report a Problem with the Last Read Aloud"
    }
  }

  private var placeholder: LocalizedStringKey {
    switch kind {
    case .dictation: return "For example: a word I didn't say was added at the end"
    case .prompt: return "For example: the answer ignored my instruction"
    case .readAloud: return "For example: a word was pronounced wrong"
    }
  }

  private var privacyNote: LocalizedStringKey {
    switch kind {
    case .dictation where sendsSettings:
      return "Contains your dictated text and your settings. Remove names before sending."
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
    let kind = candidate.menuLabel ?? kindLabel(candidate.kind)
    return "\(kind) · \(time) · \(candidate.preview)"
  }

  /// What every channel sends: the user's sentence first, because it is what the developer reads
  /// first, then the recorded details.
  private var context: String {
    let note = problem.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = details.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !note.isEmpty else { return body }
    return String(localized: "What went wrong: \(note)") + "\n\n\(body)"
  }

  private var sendsSettings: Bool { includeGlossary || includePrompts || includeTemplates }

  private var settingsOnHint: LocalizedStringKey {
    "Sent as a file."
  }

  private func sendEmail() {
    if onSend(.email, context, attachmentText) { fileOnClipboard = true }
  }

  private var settingsOffHint: LocalizedStringKey {
    "Only the details above are sent."
  }

  /// Nil when every section is off. Otherwise the edited details, the technical lines, then the
  /// configuration. Copy uses this when settings are on, so those lines travel with the settings.
  private var attachmentText: String? {
    guard includeGlossary || includePrompts || includeTemplates else { return nil }
    var parts = [context]
    if let technical = current?.technical, !technical.isEmpty {
      parts.append(technical)
    }
    parts.append(ConfigurationReport.build(.init(
      includeGlossary: includeGlossary,
      includePrompts: includePrompts,
      includeTemplates: includeTemplates)))
    return parts.joined(separator: "\n\n")
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
              ForEach(others, id: \.id) { candidate in
                Button(Self.menuTitle(candidate)) {
                  selected = candidate.id
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
        Text("The developer gets the text and the details below, so you don't have to look up the version or model. Nothing is sent until you press send in your mail app.")
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

      // On by default: without the glossary, prompts and templates a report about a wrong word
      // cannot be reproduced, and asking for them through the person who set the app up costs a
      // round trip per question. They are configuration, not patient data; the dictated text
      // above is the sensitive part and is already in the details.
      VStack(alignment: .leading, spacing: 6) {
        Text("Also send my settings")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        HStack(spacing: 18) {
          Toggle("Glossary", isOn: $includeGlossary)
          Toggle("Additional Instructions", isOn: $includePrompts)
          Toggle("Templates", isOn: $includeTemplates)
        }
        .toggleStyle(.checkbox)
        Text(sendsSettings ? settingsOnHint : settingsOffHint)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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

      if fileOnClipboard {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "doc.badge.arrow.up")
            .foregroundColor(.accentColor)
          Text("Your settings are copied as a file. Press ⌘V in the email to attach them.")
            .font(.callout)
            .fontWeight(.medium)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack(spacing: 10) {
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.cancelAction)
          .pointerCursorOnHover()

        Spacer()

        // Copy takes everything, settings included: the clipboard has no length limit.
        Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            FeedbackLinks.messageBody(context: attachmentText ?? context), forType: .string)
          copied = true
        }
        .pointerCursorOnHover()

        Button("Share…") { onShare(context, attachmentText) }
          .pointerCursorOnHover()

        // No default-action shortcut: Return in the "what went wrong" field must not send.
        if fileOnClipboard {
          Button("Done") { onCancel() }
            .buttonStyle(.borderedProminent)
            .pointerCursorOnHover()
        } else {
          Button("Send by Email") { sendEmail() }
            .buttonStyle(.borderedProminent)
            .pointerCursorOnHover()
        }
      }
    }
    .padding(20)
    .frame(minWidth: 560, minHeight: 520)
    .onChange(of: editedDetails) { copied = false }
    .onChange(of: problem) { copied = false }
  }
}
