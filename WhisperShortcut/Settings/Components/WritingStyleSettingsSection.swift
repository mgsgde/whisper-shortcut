import AppKit
import SwiftUI

/// Settings → Smart Improvement → Writing Style: toggle, Gmail import, pasted examples, profile.
/// See plans/active/writing-style.md.
struct WritingStyleSettingsSection: View {
  @AppStorage(UserDefaultsKeys.writingStyleEnabled) private var isEnabled = false
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false
  @ObservedObject private var google = GoogleAccountOAuthService.shared

  @State private var counts: [WritingContext: Int] = [:]
  @State private var isWorking = false
  @State private var statusMessage: String?
  @State private var showAddExamples = false
  @State private var showDeleteConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Writing Style",
        systemImage: "signature",
        subtitle: "Dictate Prompt drafts messages the way you write them, learned from messages you sent."
      )

      VStack(alignment: .leading, spacing: 12) {
        Toggle("Use my writing style in Dictate Prompt", isOn: $isEnabled)
          .toggleStyle(.switch)
          .help("Sends your style profile and a few of your own messages with each Dictate Prompt request, chosen by the app you are writing in (Mail, WhatsApp, Slack, …). Not used with local models.")

        Text("Examples: " + WritingContext.allCases.map { "\($0.displayName) \(counts[$0] ?? 0)" }
          .joined(separator: " · "))
          .font(.callout)
          .foregroundColor(.secondary)

        HStack(spacing: 12) {
          Button(action: importFromGmail) {
            Label("Import sent emails from Gmail", systemImage: "envelope")
              .font(.callout)
          }
          .disabled(isWorking || offlineMode || !google.isConnected)
          .pointerCursorOnHover()

          Button("Add examples…") { showAddExamples = true }
            .disabled(isWorking)
            .pointerCursorOnHover()

          if isWorking { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.bordered)

        if offlineMode {
          caption("Gmail import and profile updates are off in Offline Mode. A saved profile and examples keep working.")
        } else if !google.isConnected {
          caption("Connect your Google account (Settings → Chat) to import sent emails, or paste examples yourself.")
        }

        HStack(spacing: 12) {
          Button("Update profile", action: updateProfile)
            .disabled(isWorking || offlineMode || counts.values.reduce(0, +) == 0)
            .pointerCursorOnHover()
          Button("Edit profile…", action: openProfile)
            .pointerCursorOnHover()
          Button("Delete writing style data", role: .destructive) { showDeleteConfirmation = true }
            .tint(.red)
            .disabled(isWorking)
            .pointerCursorOnHover()
        }
        .buttonStyle(.bordered)

        if let statusMessage { caption(statusMessage) }

        caption("Stored on this Mac in the app's data folder. When on, your profile and a few of your messages are sent with each Dictate Prompt request to your Dictate Prompt model (cloud models only; local models do not get them). \"Update profile\" sends a sample of your messages to the Smart Improvement model and shows the result for review before saving.")
      }
    }
    .onAppear(perform: refreshCounts)
    .sheet(isPresented: $showAddExamples, onDismiss: refreshCounts) {
      AddWritingExamplesSheet(isPresented: $showAddExamples)
    }
    .confirmationDialog("Delete writing style data?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        WritingStyleStore.shared.clearAll()
        refreshCounts()
        statusMessage = "Writing style data deleted."
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The profile and all example messages will be deleted. Your emails are not affected.")
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func refreshCounts() {
    counts = WritingStyleStore.shared.sampleCounts()
  }

  private func importFromGmail() {
    run {
      let result = try await WritingStyleImporter.importFromGmail()
      await MainActor.run {
        refreshCounts()
        statusMessage = result.summary + " Creating your profile…"
      }
      let saved = try await WritingStyleImporter.deriveProfile()
      return result.summary + (saved == nil ? " Profile unchanged." : " Profile saved.")
    }
  }

  private func updateProfile() {
    run {
      let saved = try await WritingStyleImporter.deriveProfile()
      return saved == nil ? "Profile unchanged." : "Profile saved."
    }
  }

  private func run(_ work: @escaping () async throws -> String) {
    isWorking = true
    statusMessage = nil
    Task {
      let message: String
      do {
        message = try await work()
      } catch {
        message = error.localizedDescription
      }
      await MainActor.run {
        isWorking = false
        statusMessage = message
        refreshCounts()
      }
    }
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
