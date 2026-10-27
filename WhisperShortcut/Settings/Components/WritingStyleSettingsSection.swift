import AppKit
import SwiftUI

/// Settings → Smart Improvement → Writing Style. Learning runs on its own while the toggle is on
/// (`WritingStyleAutoUpdater`); the manual paths sit in a collapsed group for users without Gmail.
/// See plans/active/writing-style.md.
struct WritingStyleSettingsSection: View {
  @AppStorage(UserDefaultsKeys.writingStyleEnabled) private var isEnabled = false
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false
  @ObservedObject private var google = GoogleAccountOAuthService.shared
  @ObservedObject private var updater = WritingStyleAutoUpdater.shared

  @State private var counts: [WritingContext: Int] = [:]
  @State private var profileUpdatedAt: Date?
  @State private var showManual = false
  @State private var showAddExamples = false
  @State private var showDeleteConfirmation = false

  private var emailCount: Int { counts[.email] ?? 0 }
  private var messageCount: Int { counts.filter { $0.key != .email }.values.reduce(0, +) }
  private var hasData: Bool { emailCount + messageCount > 0 || profileUpdatedAt != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Writing Style",
        systemImage: "signature",
        subtitle: "Dictate Prompt drafts messages the way you write them. The app learns your style by itself from emails you sent and from what you dictate into Mail, Messages, WhatsApp or Slack."
      )

      VStack(alignment: .leading, spacing: 12) {
        Toggle("Use my writing style in Dictate Prompt", isOn: $isEnabled)
          .toggleStyle(.switch)
          .help("Learns from your sent emails and your dictations, and sends your style profile plus a few of your messages with each Dictate Prompt request, chosen by the app you are writing in. Not used with local models.")

        if isEnabled || hasData {
          statusLine
        }

        if isEnabled || hasData {
          HStack(spacing: 12) {
            Button("Edit profile…", action: openProfile)
              .pointerCursorOnHover()
            Button("Delete writing style data", role: .destructive) { showDeleteConfirmation = true }
              .tint(.red)
              .disabled(updater.isWorking || !hasData)
              .pointerCursorOnHover()
          }
          .buttonStyle(.bordered)
        }

        if isEnabled {
          manualGroup
        }

        caption(privacyText)
      }
    }
    .onAppear(perform: refresh)
    .onChange(of: updater.isWorking) { _, working in
      if !working { refresh() }
    }
    .onChange(of: isEnabled) { _, enabled in
      guard enabled else { return }
      Task { await updater.handleEnabled() }
    }
    .sheet(isPresented: $showAddExamples, onDismiss: refresh) {
      AddWritingExamplesSheet(isPresented: $showAddExamples)
    }
    .confirmationDialog("Delete writing style data?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        WritingStyleStore.shared.clearAll()
        refresh()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The profile and all example messages will be deleted. Your emails are not affected.")
    }
  }

  // MARK: - Status

  /// One line that answers "is it doing anything?": what was learned, and when the profile last changed.
  @ViewBuilder
  private var statusLine: some View {
    HStack(spacing: 8) {
      if updater.isWorking {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: emailCount + messageCount > 0 ? "checkmark.circle.fill" : "clock")
          .foregroundColor(emailCount + messageCount > 0 ? .green : .secondary)
      }
      Text(verbatim: updater.isWorking ? String(localized: "Learning your writing style…") : statusText)
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    if !updater.isWorking, let message = updater.lastMessage {
      caption(verbatim: message)
    }
  }

  private var statusText: String {
    let total = emailCount + messageCount
    guard total > 0 else {
      if !isEnabled { return String(localized: "Nothing learned yet.") }
      return offlineMode || !google.isConnected
        ? String(localized: "Learning starts with your next dictation in Mail, Messages, WhatsApp or Slack.")
        : String(localized: "Learning starts with your sent emails and your next dictations.")
    }
    let emails = String(localized: "\(emailCount) emails", comment: "Plural variation on the number")
    let messages = String(localized: "\(messageCount) messages", comment: "Plural variation on the number")
    let learned: String
    if emailCount > 0 && messageCount > 0 {
      learned = String(localized: "Learned from \(emails) and \(messages)")
    } else if emailCount > 0 {
      learned = String(localized: "Learned from \(emails)")
    } else {
      learned = String(localized: "Learned from \(messages)")
    }
    guard let profileUpdatedAt else {
      let missing = max(WritingStyleAutoUpdater.profileThreshold - total, 0)
      return missing > 0
        ? String(localized: "\(learned) · profile follows after \(missing) more messages", comment: "Plural variation on the number of messages")
        : String(localized: "\(learned) · profile follows with the next update")
    }
    return String(localized: "\(learned) · profile updated \(Self.relative(profileUpdatedAt))")
  }

  private static func relative(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return String(localized: "today") }
    if Calendar.current.isDateInYesterday(date) { return String(localized: "yesterday") }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  // MARK: - Manual

  /// For users without Gmail, or who want the profile now instead of after the next 20 messages.
  private var manualGroup: some View {
    DisclosureGroup(isExpanded: $showManual) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          Button {
            Task { await updater.importNow() }
          } label: {
            Label("Import sent emails from Gmail", systemImage: "envelope")
          }
          .disabled(updater.isWorking || offlineMode || !google.isConnected)
          .pointerCursorOnHover()

          Button("Add examples…") { showAddExamples = true }
            .disabled(updater.isWorking)
            .pointerCursorOnHover()

          Button("Update profile now") {
            Task { await updater.updateProfileNow() }
          }
          .disabled(updater.isWorking || offlineMode || emailCount + messageCount == 0)
          .pointerCursorOnHover()
        }
        .buttonStyle(.bordered)

        if offlineMode {
          caption("Gmail import and profile updates are off in Offline Mode. A saved profile and examples keep working.")
        } else if !google.isConnected {
          caption("Connect your Google account (Settings → Accounts) and sent emails are imported automatically, or paste messages you wrote with Add examples.")
        }
      }
      .padding(.top, 8)
    } label: {
      Text("Add more manually")
        .font(.callout)
    }
  }

  private var privacyText: LocalizedStringKey {
    "Stored on this Mac in the app's data folder. While on, what you dictate into mail, messenger and work chat apps is kept as an example, and if your Google account is connected, emails you sent are imported once a week. Each Dictate Prompt request sends your profile and a few of these messages to your Dictate Prompt model (cloud models only; local models do not get them). When about 20 new messages have come in, the Smart Improvement model drafts an updated profile from a sample of them and shows it for your review before saving."
  }

  private func caption(verbatim text: String) -> some View {
    Text(verbatim: text)
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func caption(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func refresh() {
    counts = WritingStyleStore.shared.sampleCounts()
    profileUpdatedAt = WritingStyleStore.shared.profileUpdatedAt
  }

  private func openProfile() {
    let store = WritingStyleStore.shared
    store.ensureProfileFileExists()
    NSWorkspace.shared.open(store.profileURL)
  }
}

/// Paste messages you wrote; `---` on its own line separates them.
private struct AddWritingExamplesSheet: View {
  @Binding var isPresented: Bool
  @State private var context: WritingContext = .email
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add examples").font(.headline)
      Picker("Context", selection: $context) {
        ForEach(WritingContext.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      .fixedSize()
      Text("Paste one or more messages you wrote yourself. Separate messages with a line containing only ---.")
        .font(.caption)
        .foregroundColor(.secondary)
      TextEditor(text: $text)
        .font(.body)
        .frame(minWidth: 480, minHeight: 240)
        .border(Color.secondary.opacity(0.3))
      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          save()
          isPresented = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
  }

  private func save() {
    let messages = text
      .components(separatedBy: .newlines)
      .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces) == "---" })
      .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let now = Date()
    let samples = messages.map {
      WritingSample(
        id: UUID().uuidString, context: context, source: "manual", recipient: nil,
        sentAt: now, incomingChars: nil, text: $0)
    }
    let added = WritingStyleStore.shared.addSamples(samples)
    DebugLogger.log("WRITING-STYLE: manual examples added=\(added) context=\(context.rawValue)")
  }
}
