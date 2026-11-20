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

  /// One window at a time. A second open closes the current window and opens a fresh one with the
  /// new text, so a report started from an error does not keep the previous draft.
  func show(
    candidates: [ResultReport.Candidate], message: String? = nil, startOnGeneral: Bool = false
  ) {
    guard !candidates.isEmpty else {
      DebugLogger.logWarning("DICTATION-REPORT: Open requested with no candidates")
      return
    }
    if let existing = window {
      DebugLogger.log("DICTATION-REPORT: Closing the open report window to show new content")
      existing.delegate = nil
      window = nil
      existing.close()
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 660, height: 380),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = String(localized: "Report a Problem")
    window.contentView = NSHostingView(rootView: DictationReportView(
      candidates: candidates,
      initialMessage: message,
      startOnGeneral: startOnGeneral,
      onSend: { [weak self] channel, context, attachment in
        self?.send(channel, context: context, attachment: attachment) ?? false
      },
      onShare: { [weak self] context, attachment in
        self?.share(context: context, attachment: attachment)
      },
      onPreview: { [weak self] text in self?.preview(text) },
      onCancel: { [weak self] in self?.close() }))
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    let selectedID = ProblemReport.initialSelection(
      candidates: candidates, startOnGeneral: startOnGeneral)
    let opened = candidates.first { $0.id == selectedID } ?? candidates[0]
    DebugLogger.log(
      "DICTATION-REPORT: Opened report window on \(opened.kind.rawValue) (\(candidates.count) results, \(opened.details.count) chars)")
  }

  /// True when the report file was revealed in Finder for the user to drag in: the window then
  /// stays open and says so, because the message alone does not carry the settings.
  private func send(_ channel: FeedbackLinks.Channel, context: String, attachment: String? = nil)
    -> Bool
  {
    // `mailto:` carries the text in the URL, and an over-long one is dropped silently
    // by some clients instead of failing — clamp it so the report at least arrives.
    let clamped = FeedbackLinks.truncated(context, limit: 6_000)
    guard let attachment else {
      openClamped(channel, context: clamped)
      return false
    }
    return sendEmail(clampedContext: clamped, attachment: attachment)
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

  /// "View Report": writes the same file the send buttons would and opens it, so the user sees
  /// exactly what leaves the Mac before sending it.
  func preview(_ text: String) {
    do {
      let file = try ReportAttachment.write(text)
      NSWorkspace.shared.open(file)
      DebugLogger.log("DICTATION-REPORT: Opened \(file.lastPathComponent) for review")
    } catch {
      DebugLogger.logWarning(
        "DICTATION-REPORT: Could not write the report file: \(error.logDescription)")
      showSettingsFileAlert()
    }
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
  /// One switch for the whole configuration (glossary, instructions, templates, settings). Parts
  /// of it cannot reproduce a report, so there is nothing to pick; off is for the rare user who
  /// will not send any of it.
  @State private var includeConfiguration = true
  @State private var showDetails = false
  /// Set after an email send that could not attach the file (no Apple Mail); the window stays
  /// open and says how to add it, since the mail does not have it yet.
  @State private var fileOnClipboard = false
  /// Returns true when the report file was revealed in Finder instead of attached.
  let onSend: (_ channel: FeedbackLinks.Channel, _ context: String, _ attachment: String?) -> Bool
  let onShare: (_ context: String, _ attachment: String?) -> Void
  let onPreview: (_ text: String) -> Void
  let onCancel: () -> Void

  init(
    candidates: [ResultReport.Candidate],
    initialMessage: String? = nil,
    startOnGeneral: Bool = false,
    onSend: @escaping (_ channel: FeedbackLinks.Channel, _ context: String, _ attachment: String?) -> Bool,
    onShare: @escaping (_ context: String, _ attachment: String?) -> Void,
    onPreview: @escaping (_ text: String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.candidates = candidates
    self._selected = State(initialValue: ProblemReport.initialSelection(
      candidates: candidates, startOnGeneral: startOnGeneral))
    self._problem = State(initialValue: initialMessage ?? "")
    self.onSend = onSend
    self.onShare = onShare
    self.onPreview = onPreview
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

  private var messageLabel: LocalizedStringKey {
    kind == .general ? "Your message" : "What went wrong?"
  }

  private var placeholder: LocalizedStringKey {
    switch kind {
    case .dictation: return "For example: a word I didn't say was added at the end"
    case .prompt: return "For example: the answer ignored my instruction"
    case .readAloud: return "For example: a word was pronounced wrong"
    case .general: return "For example: an idea, a question, or what did not work"
    }
  }

  private var privacyNote: LocalizedStringKey {
    switch (kind, includeConfiguration) {
    case (.general, _):
      return "Contains your settings. Remove names before sending."
    case (.dictation, true):
      return "Contains your dictated text and your settings. Remove names before sending."
    case (_, true):
      return "Contains the text of this result and your settings. Remove names before sending."
    case (.dictation, false):
      return "Contains your dictated text. Remove names or anything else private before you send it."
    case (.prompt, false):
      return "Contains your instruction, part of the selected text and the answer. Remove names or anything else private before you send it."
    case (.readAloud, false):
      return "Contains the text that was read aloud. Remove names or anything else private before you send it."
    }
  }

  private static func kindLabel(_ kind: ResultReport.Kind) -> String {
    switch kind {
    case .dictation: return String(localized: "Dictation")
    case .prompt: return String(localized: "Prompt Answer")
    case .readAloud: return String(localized: "Read Aloud")
    case .general: return String(localized: "General Feedback (no specific result)")
    }
  }

  /// "Prompt Answer · 08:02 · Fasse das kurz zusammen…": what it was, when, and how it started,
  /// which is enough to recognise it without opening it. General feedback has neither.
  private static func menuTitle(_ candidate: ResultReport.Candidate) -> String {
    guard candidate.kind != .general else { return kindLabel(.general) }
    let time = candidate.ts.formatted(date: .omitted, time: .shortened)
    let kind = candidate.menuLabel ?? kindLabel(candidate.kind)
    let preview = candidate.preview.count > 48
      ? String(candidate.preview.prefix(48)) + "…" : candidate.preview
    return "\(kind) · \(time) · \(preview)"
  }

  /// What every channel sends: the user's sentence first, because it is what the developer reads
  /// first, then the recorded details.
  private var context: String {
    let note = problem.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = details.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !note.isEmpty else { return body }
    return String(localized: "What went wrong: \(note)") + "\n\n\(body)"
  }

  private func sendEmail() {
    if onSend(.email, context, attachmentText) { fileOnClipboard = true }
  }

  /// Nil when the configuration is off. Otherwise the edited details, the technical lines, then
  /// the configuration. Copy uses this too, so those lines travel with it.
  private var attachmentText: String? {
    guard includeConfiguration else { return nil }
    var parts = [context]
    if let technical = current?.technical, !technical.isEmpty {
      parts.append(technical)
    }
    parts.append(ConfigurationReport.build(.init(
      includeGlossary: true, includePrompts: true, includeTemplates: true)))
    return parts.joined(separator: "\n\n")
  }

  private func sectionLabel(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.subheadline)
      .fontWeight(.medium)
      .foregroundColor(.secondary)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        sectionLabel("What is it about?")
        Picker("What is it about?", selection: $selected) {
          ForEach(candidates, id: \.id) { candidate in
            Text(Self.menuTitle(candidate)).tag(candidate.id)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .pointerCursorOnHover()
        .onChange(of: selected) { _, id in
          copied = false
          DebugLogger.log("DICTATION-REPORT: Switched to \(id)")
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        sectionLabel(messageLabel)
        TextField(placeholder, text: $problem, axis: .vertical)
          .lineLimit(3...6)
          .textFieldStyle(.roundedBorder)
      }

      // Collapsed: the recorded facts matter to the developer, not to the person reporting.
      // Open, they can be read and edited (a patient name in the dictated text, say).
      DisclosureGroup(isExpanded: $showDetails) {
        TextEditor(text: details)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(4)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
          .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
          .frame(minHeight: 180)
          .padding(.top, 6)
      } label: {
        sectionLabel("Details (editable)")
          .contentShape(Rectangle())
          .onTapGesture { withAnimation { showDetails.toggle() } }
      }

      // On by default: without the configuration a report about a wrong word cannot be
      // reproduced, and asking for it through the person who set the app up costs a round trip.
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Toggle(
          "Send my configuration (glossary, instructions, templates, settings)",
          isOn: $includeConfiguration
        )
        .toggleStyle(.checkbox)
        Spacer(minLength: 0)
        if let text = attachmentText {
          Button("View Report") { onPreview(text) }
            .buttonStyle(.link)
            .pointerCursorOnHover()
        }
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
          Text("The file is selected in Finder and copied. Press ⌘V in the email or drag the file into it.")
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

        // Copy takes everything, configuration included: the clipboard has no length limit, and
        // it is the one route that works from Citrix or a remote Outlook.
        Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            FeedbackLinks.messageBody(context: attachmentText ?? context), forType: .string)
          copied = true
        }
        .pointerCursorOnHover()

        Button("Share…") { onShare(context, attachmentText) }
          .pointerCursorOnHover()

        // No default-action shortcut: Return in the message field must not send.
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
    .frame(minWidth: 600)
    // Exactly as tall as its content: the window grows when Details opens instead of leaving an
    // empty area under the buttons.
    .fixedSize(horizontal: false, vertical: true)
    .onChange(of: editedDetails) { copied = false }
    .onChange(of: problem) { copied = false }
  }
}
