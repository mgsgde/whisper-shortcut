import AppKit
import SwiftUI

/// The one "Report a Problem" window.
///
/// The menu bar, Settings → About, an error popup, `/feedback` and an MCP problem report all
/// open this window. The user edits the message and the details, then sends by email, shares the
/// report file, or copies it. The file is the same text the mail carries: the report, then the
/// app and macOS version and the hang excerpt, then the technical lines, then the configuration
/// (glossary, instructions, templates, settings) when that switch is on. Nothing leaves the Mac
/// until they press send in their mail app.
final class DictationReportWindowController: NSObject, NSWindowDelegate {

  static let shared = DictationReportWindowController()

  private var window: NSWindow?
  /// The user changed the message or the details since this window opened. A new open keeps it.
  private var draftEdited = false
  /// Set once, the first time this window's report is sent, shared or copied.
  private var didHandOff = false
  private var onHandedOff: ((String) -> Void)?

  /// True while a report window is on screen, edited or not.
  var isShowing: Bool { window != nil }

  /// The text written to the report file, copied, and attached to the mail. `messageBody` first
  /// (the report, the hang excerpt, app and macOS version), then technical lines, then the
  /// configuration. One build, so every route carries the same footer.
  static func fileText(context: String, technical: String, configuration: String?) -> String {
    var parts = [FeedbackLinks.messageBody(context: context)]
    let technical = technical.trimmingCharacters(in: .whitespacesAndNewlines)
    if !technical.isEmpty { parts.append(technical) }
    if let configuration = configuration?.trimmingCharacters(in: .whitespacesAndNewlines),
      !configuration.isEmpty
    {
      parts.append(configuration)
    }
    return parts.joined(separator: "\n\n")
  }

  /// One window at a time. An edited draft stays; an untouched window is replaced. `activate` is
  /// false when the window must not take the keyboard (an MCP report arriving while the user types).
  func show(
    candidates: [ResultReport.Candidate],
    message: String? = nil,
    startOnGeneral: Bool = false,
    activate: Bool = true,
    onHandedOff: ((String) -> Void)? = nil
  ) {
    guard !candidates.isEmpty else {
      DebugLogger.logWarning("DICTATION-REPORT: Open requested with no candidates")
      return
    }
    if let existing = window {
      if draftEdited {
        DebugLogger.log("DICTATION-REPORT: Kept the open draft")
        present(existing, activate: activate)
        return
      }
      DebugLogger.log("DICTATION-REPORT: Closing the open report window to show new content")
      existing.delegate = nil
      window = nil
      existing.close()
    }
    draftEdited = false
    didHandOff = false
    self.onHandedOff = onHandedOff
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
      onCancel: { [weak self] in self?.close() },
      onEditedChange: { [weak self] edited in
        self?.draftEdited = edited
      },
      onHandedOff: { [weak self] body in
        self?.noteHandedOff(body)
      }))
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    self.window = window
    present(window, activate: activate)
    let selectedID = ProblemReport.initialSelection(
      candidates: candidates, startOnGeneral: startOnGeneral)
    let opened = candidates.first { $0.id == selectedID } ?? candidates[0]
    DebugLogger.log(
      "DICTATION-REPORT: Opened report window on \(opened.kind.rawValue) (\(candidates.count) results, \(opened.details.count) chars)")
  }

  /// `activate` makes the window key and brings the app forward. Otherwise the window comes
  /// forward without taking the keyboard.
  private func present(_ window: NSWindow, activate: Bool) {
    if activate {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    } else {
      window.orderFront(nil)
    }
  }

  /// The first send, share or copy hands the report text to the opener (an MCP proposal accepts
  /// here). Later presses, and Cancel, do not.
  private func noteHandedOff(_ body: String) {
    guard !didHandOff else { return }
    didHandOff = true
    onHandedOff?(body)
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
      noteHandedOff(FeedbackLinks.messageBody(context: context))
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
        noteHandedOff(attachment)
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
    noteHandedOff(attachment)
    return true
  }

  /// The message names the file, so the developer notices when it was not pasted.
  static func withFileNote(_ context: String, file: URL) -> String {
    context + "\n\n" + String(localized: "Configuration as a file: \(file.lastPathComponent)")
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
    noteHandedOff(text)
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
    draftEdited = false
    didHandOff = false
    onHandedOff = nil
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
  /// True when the message differs from what the window opened with, or any details were edited.
  let onEditedChange: (Bool) -> Void
  /// The report text the first time the user sends, shares or copies.
  let onHandedOff: (String) -> Void
  /// The message field's text when the window opened. Compared to `problem` to see a draft.
  private let openedProblem: String

  init(
    candidates: [ResultReport.Candidate],
    initialMessage: String? = nil,
    startOnGeneral: Bool = false,
    onSend: @escaping (_ channel: FeedbackLinks.Channel, _ context: String, _ attachment: String?) -> Bool,
    onShare: @escaping (_ context: String, _ attachment: String?) -> Void,
    onPreview: @escaping (_ text: String) -> Void,
    onCancel: @escaping () -> Void,
    onEditedChange: @escaping (Bool) -> Void,
    onHandedOff: @escaping (String) -> Void
  ) {
    self.candidates = candidates
    self._selected = State(initialValue: ProblemReport.initialSelection(
      candidates: candidates, startOnGeneral: startOnGeneral))
    let opened = initialMessage ?? ""
    self.openedProblem = opened
    self._problem = State(initialValue: opened)
    self.onSend = onSend
    self.onShare = onShare
    self.onPreview = onPreview
    self.onCancel = onCancel
    self.onEditedChange = onEditedChange
    self.onHandedOff = onHandedOff
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
    // The configuration cannot be edited here, so the note only asks for what the user can do:
    // names in the text, under Details.
    case (.general, true):
      return "Contains your message and your configuration, including the glossary."
    case (.general, false):
      return "Contains only your message, the app version and the macOS version."
    case (.dictation, true):
      return "Contains your dictated text and your configuration, including the glossary. You can remove names from the text under Details."
    case (_, true):
      return "Contains the text of this result and your configuration, including the glossary. You can remove names from the text under Details."
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
    let lead = kind == .general
      ? String(localized: "Message: \(note)") : String(localized: "What went wrong: \(note)")
    return lead + "\n\n\(body)"
  }

  private func sendEmail() {
    let text = reportFileText
    let attachment = includeConfiguration ? text : nil
    if onSend(.email, context, attachment) { fileOnClipboard = true }
  }

  /// What Send attaches, Share writes, View Report opens and Copy puts on the clipboard.
  /// The configuration section is omitted when the switch is off.
  private var reportFileText: String {
    let configuration = includeConfiguration
      ? ConfigurationReport.build(.init(
        includeGlossary: true, includePrompts: true, includeTemplates: true))
      : nil
    return DictationReportWindowController.fileText(
      context: context,
      technical: current?.technical ?? "",
      configuration: configuration)
  }

  /// True when the message or the details differ from what this window opened with.
  private func publishEdited() {
    let messageDiffers = problem != openedProblem
    let detailsEdited = editedDetails.contains { id, text in
      let original = candidates.first { $0.id == id }?.details ?? ""
      return text != original
    }
    onEditedChange(messageDiffers || detailsEdited)
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
        sectionLabel("View and edit details")
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
        if includeConfiguration {
          Button("View Report") { onPreview(reportFileText) }
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
          let text = reportFileText
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
          copied = true
          onHandedOff(text)
        }
        .pointerCursorOnHover()

        Button("Share…") { onShare(context, reportFileText) }
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
    .onChange(of: editedDetails) {
      copied = false
      publishEdited()
    }
    .onChange(of: problem) {
      copied = false
      publishEdited()
    }
  }
}
