import SwiftUI

/// "Send My Settings": shows exactly what would be shared, lets the user cut anything out of it,
/// and hands the result to their own mail or WhatsApp client.
///
/// Built for the round-trip it replaces: a tester says "it wrote something random", and the
/// developer has to ask, one message at a time, for the version, the model, the glossary and the
/// prompt — and usually gets the wrong prompt section back. One press here answers all of it.
///
/// Privacy is structural, in three layers:
/// 1. The base text holds no free text the user wrote: settings, models, shortcuts, which prompt
///    sections are customized, and (only with "Save usage data" on) content-free usage counts.
/// 2. Glossary and system prompts are content and may hold names, so each is its own opt-in
///    checkbox, off by default.
/// 3. The preview is editable. What is in the field when a button is pressed is what is shared,
///    so the user can delete lines first.
///
/// Once the preview has been edited the checkboxes lock: rebuilding would bring back a line the
/// user had just removed. "Start over" is the explicit way back. The "What happened?" note is a
/// separate field for that reason — describing the problem must not lock the checkboxes.
struct FeedbackReportSheet: View {
  /// Usage counts, or nil when "Save usage data" is off.
  let usageReport: String?
  let onDismiss: () -> Void

  @State private var note = ""
  @State private var includeGlossary = false
  @State private var includePrompts = false
  @State private var draft = ""
  @State private var isEdited = false
  @State private var copied = false

  /// `wa.me` and `mailto:` carry the text inside the URL, and clients silently drop an over-long
  /// one (see `FeedbackLinks`). Past this, sending goes through the clipboard instead.
  private static let linkLimit = 1_200

  private var options: ConfigurationReport.Options {
    .init(includeGlossary: includeGlossary, includePrompts: includePrompts)
  }

  /// What leaves the sheet: the note first, so the problem is the first thing the developer reads.
  private var message: String {
    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return [trimmedNote, draft.trimmingCharacters(in: .whitespacesAndNewlines)]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  private var fitsInLink: Bool { message.count <= Self.linkLimit }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Send my settings")
          .font(.headline)
        Text(
          "Nothing leaves your Mac automatically. Send opens your own WhatsApp or mail with this text, and you press send there. Delete anything below that you don't want to share."
        )
        .font(.subheadline)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      TextField("What happened? (optional)", text: $note, axis: .vertical)
        .lineLimit(2...4)
        .textFieldStyle(.roundedBorder)

      VStack(alignment: .leading, spacing: 6) {
        Toggle("Include my glossary", isOn: $includeGlossary)
        Toggle("Include my system prompts", isOn: $includePrompts)
        Text(
          isEdited
            ? "You edited the text below, so these are locked. Press Start over to change them."
            : "Glossary and prompts can contain names. Both stay out unless you tick them."
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .disabled(isEdited)
      .onChange(of: includeGlossary) { _, _ in rebuild() }
      .onChange(of: includePrompts) { _, _ in rebuild() }

      TextEditor(
        text: Binding(
          get: { draft },
          set: { newValue in
            if newValue != draft { isEdited = true }
            draft = newValue
            copied = false
          })
      )
      .font(.system(.callout, design: .monospaced))
      .scrollContentBackground(.hidden)
      .padding(8)
      .background(Color(NSColor.controlBackgroundColor))
      .cornerRadius(SettingsConstants.cornerRadius)

      if !fitsInLink {
        Label(
          "Too long to prefill. Sending copies it instead: paste it with ⌘V in the chat or email that opens.",
          systemImage: "doc.on.clipboard"
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 12) {
        Button("Cancel", action: onDismiss)
          .keyboardShortcut(.cancelAction)

        if isEdited {
          Button("Start over") {
            isEdited = false
            rebuild()
          }
        }

        Spacer()

        Button(copied ? ("Copied!" as LocalizedStringKey) : "Copy", action: copyMessage)

        Button("Send via Email") { send(.email) }

        Button("Send via WhatsApp") { send(.whatsApp) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 620, height: 660)
    // Built here, not in init: SwiftUI re-creates this struct whenever the settings window redraws,
    // and the report reads system-prompts.md from disk.
    .onAppear { rebuild() }
    .onChange(of: note) { _, _ in copied = false }
  }

  private func copyMessage() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message, forType: .string)
    copied = true
  }

  /// A short message goes prefilled. A long one would be silently dropped by the URL, so it goes
  /// through the clipboard and the channel opens with only the greeting and version line.
  private func send(_ channel: FeedbackLinks.Channel) {
    if fitsInLink {
      FeedbackLinks.open(channel, context: message)
    } else {
      copyMessage()
      FeedbackLinks.open(channel, context: nil)
    }
    onDismiss()
  }

  private func rebuild() {
    draft = [usageReport, ConfigurationReport.build(options)]
      .compactMap { $0 }
      .joined(separator: "\n\n")
    copied = false
  }
}
