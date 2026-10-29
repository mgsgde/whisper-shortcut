import SwiftUI

/// Settings → Privacy & Permissions → "Features You Use": what `FeatureUsageStore` counted on this
/// Mac. It exists to answer "which of these do I actually use?", so unused features are listed as
/// prominently as used ones, grouped by area so a whole dead area is visible at a glance.
struct FeatureUsageSection: View {
  @State private var showingDetails = false
  @State private var snapshot = FeatureUsageSummary.load()

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Features You Use")
        .font(.callout)
        .fontWeight(.semibold)
      Text("Counted on this Mac since \(snapshot.since.formatted(date: .abbreviated, time: .omitted)). Never sent — it only shows which features you rely on and which you never touch.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Text("\(snapshot.recentlyUsedCount) of \(TelemetryFeature.allCases.count) features used in the last 30 days")
          .font(.caption)
        Button("Show Feature Usage…") { showingDetails = true }
          .buttonStyle(.link)
          .font(.caption)
          .pointerCursorOnHover()
      }
    }
    .padding(SettingsConstants.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
    .onAppear { snapshot = FeatureUsageSummary.load() }
    .sheet(isPresented: $showingDetails, onDismiss: { snapshot = FeatureUsageSummary.load() }) {
      FeatureUsageSheet(onDismiss: { showingDetails = false })
    }
  }
}

/// The store's snapshot, shaped for display.
struct FeatureUsageSummary {
  static let recentDays = 30

  let since: Date
  let entries: [TelemetryFeature: FeatureUsageStore.Entry]
  let now: Date

  static func load(now: Date = Date()) -> FeatureUsageSummary {
    let snapshot = FeatureUsageStore.shared.snapshot()
    return FeatureUsageSummary(since: snapshot.since, entries: snapshot.entries, now: now)
  }

  func isRecent(_ feature: TelemetryFeature) -> Bool {
    guard let lastUsed = entries[feature]?.lastUsed else { return false }
    return now.timeIntervalSince(lastUsed) < Double(Self.recentDays) * 86_400
  }

  var recentlyUsedCount: Int { TelemetryFeature.allCases.filter(isRecent).count }

  /// Used features first (most used on top), then the rest in declaration order.
  func features(in group: TelemetryFeatureGroup) -> [TelemetryFeature] {
    let all = TelemetryFeature.allCases.filter { $0.group == group }
    let used = all.filter { entries[$0] != nil }.sorted { (entries[$0]?.count ?? 0) > (entries[$1]?.count ?? 0) }
    return used + all.filter { entries[$0] == nil }
  }
}

struct FeatureUsageSheet: View {
  let onDismiss: () -> Void
  @State private var summary = FeatureUsageSummary.load()
  @State private var confirmingReset = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Feature Usage")
          .font(.headline)
        Text("Counted on this Mac since \(summary.since.formatted(date: .abbreviated, time: .omitted)). Nothing here leaves this Mac. Greyed-out features were not used in the last 30 days.")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(TelemetryFeatureGroup.allCases, id: \.self) { group in
            groupSection(group)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
      .background(Color(NSColor.controlBackgroundColor))
      .cornerRadius(SettingsConstants.cornerRadius)

      HStack {
        Button("Reset Counts…", role: .destructive) { confirmingReset = true }
        Spacer()
        Button("Done", action: onDismiss)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560, height: 620)
    .confirmationDialog("Reset feature counts?", isPresented: $confirmingReset) {
      Button("Reset", role: .destructive) {
        FeatureUsageStore.shared.reset()
        summary = FeatureUsageSummary.load()
      }
    } message: {
      Text("Counting starts again from today. Your settings and usage log are not affected.")
    }
  }

  @ViewBuilder
  private func groupSection(_ group: TelemetryFeatureGroup) -> some View {
    let features = summary.features(in: group)
    let recent = features.filter(summary.isRecent).count
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(group.displayName)
          .font(.subheadline)
          .fontWeight(.semibold)
        Spacer()
        Text("\(recent) of \(features.count) used")
          .font(.caption)
          .foregroundStyle(recent == 0 ? .orange : .secondary)
      }
      VStack(spacing: 0) {
        ForEach(features, id: \.self) { feature in
          row(feature)
          if feature != features.last { Divider() }
        }
      }
    }
  }

  private func row(_ feature: TelemetryFeature) -> some View {
    let entry = summary.entries[feature]
    let recent = summary.isRecent(feature)
    return HStack(alignment: .firstTextBaseline, spacing: 12) {
      feature.label
        .font(.callout)
        .foregroundStyle(recent ? .primary : .secondary)
      Spacer(minLength: 8)
      if let entry {
        Text(Self.lastUsedText(entry.lastUsed, now: summary.now))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(verbatim: "\(entry.count)×")
          .font(.callout.monospacedDigit())
          .foregroundStyle(recent ? .primary : .secondary)
          .frame(minWidth: 44, alignment: .trailing)
      } else {
        Text("Never")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 5)
  }

  static func lastUsedText(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today") }
    return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
  }
}

extension TelemetryFeatureGroup {
  var displayName: String {
    switch self {
    case .core: String(localized: "Basics")
    case .dictatePrompt: String(localized: "Dictate Prompt")
    case .dictation: String(localized: "Dictation Extras")
    case .readAloud: String(localized: "Read Aloud")
    case .providers: String(localized: "Providers")
    case .chatCommands: String(localized: "Chat Commands")
    case .chatContent: String(localized: "Chat Content")
    case .chatTools: String(localized: "Chat Tools")
    case .meetings: String(localized: "Meetings")
    case .aiApps: String(localized: "Claude & AI Apps")
    case .smartImprovement: String(localized: "Smart Improvement")
    case .support: String(localized: "Support & Updates")
    }
  }
}

extension TelemetryFeature {
  /// Slash commands are shown as typed and never translated; everything else is a localized name.
  @ViewBuilder var label: some View {
    if let command = slashCommand {
      Text(verbatim: command).font(.system(.callout, design: .monospaced))
    } else {
      Text(displayName)
    }
  }

  var slashCommand: String? {
    switch self {
    case .chatCommandNew: "/new"
    case .chatCommandScreenshot: "/screenshot"
    case .chatCommandAttach: "/attach"
    case .chatCommandFolder: "/folder"
    case .chatCommandWorkspace: "/workspace"
    case .chatCommandModelSwitch: "/model, /gemini, /grok …"
    case .chatCommandThink: "/think"
    case .chatCommandX: "/x"
    case .chatCommandSettings: "/settings"
    case .chatCommandPin: "/pin, /unpin"
    case .chatCommandMeeting: "/meeting"
    case .chatCommandCopy: "/copy"
    case .chatCommandFeedback: "/feedback"
    default: nil
    }
  }

  var displayName: String {
    switch self {
    case .dictation: String(localized: "Dictate")
    case .dictatePrompt: String(localized: "Dictate Prompt")
    case .chat: String(localized: "Chat")
    case .readAloud: String(localized: "Read Aloud")
    case .meeting: String(localized: "Live Meeting")
    case .dictatePromptWithSelection: String(localized: "Edit selected text")
    case .dictatePromptWithScreenshot: String(localized: "Include a screenshot")
    case .dictatePromptQuickPrompt: String(localized: "Quick prompts")
    case .dictatePromptTypedInstruction: String(localized: "Typed instruction")
    case .dictatePromptLookup: String(localized: "Look things up while writing")
    case .writingStyleApplied: String(localized: "Writing Style")
    case .glossaryAddSelection: String(localized: "Add Selection to Glossary")
    case .copyLastTranscription: String(localized: "Copy Last Transcription")
    case .recentTranscriptionCopied: String(localized: "Recent Transcriptions")
    case .offlineMode: String(localized: "Offline Mode")
    case .screenshotMenu: String(localized: "Screenshot from the menu bar")
    case .readAloudSmartRewrite: String(localized: "Smart Rewrite")
    case .ownServer: String(localized: "Your own server")
    case .openRouter: String(localized: "OpenRouter")
    case .chatGPTPlan: String(localized: "ChatGPT plan")
    case .chatUserCommand: String(localized: "Your own commands")
    case .chatImageAttachment: String(localized: "Image and file attachments")
    case .chatWebSearch: String(localized: "Web search")
    case .chatYouTube: String(localized: "YouTube videos")
    case .chatToolGoogle: String(localized: "Google Calendar, Tasks and Gmail")
    case .chatToolTrello: String(localized: "Trello")
    case .chatToolMail: String(localized: "Mail accounts (IMAP)")
    case .chatToolFolderRead: String(localized: "Read shared folders")
    case .chatToolFolderWrite: String(localized: "Edit files in shared folders")
    case .chatToolImageGeneration: String(localized: "Image generation")
    case .chatToolMemory: String(localized: "Remember facts about you")
    case .chatToolMeeting: String(localized: "Meeting tools")
    case .meetingLiveNotes: String(localized: "Live notes")
    case .meetingSummary: String(localized: "Meeting summary")
    case .meetingRetryTranscription: String(localized: "Retry Meeting Transcription")
    case .mcpRead: String(localized: "Read by AI apps")
    case .mcpChange: String(localized: "Changes made by AI apps")
    case .smartImprovementRun: String(localized: "Smart Improvement runs")
    case .smartImprovementAccepted: String(localized: "Accepted suggestions")
    case .sendFeedback: String(localized: "Send Feedback")
    case .reportProblemLastDictation: String(localized: "Report a Problem with Last Dictation")
    case .shareUsageReport: String(localized: "Share Usage Report")
    case .welcomeTourReopened: String(localized: "Welcome Tour, reopened")
    case .checkForUpdatesManual: String(localized: "Check for Updates")
    case .chatCommandNew, .chatCommandScreenshot, .chatCommandAttach, .chatCommandFolder,
      .chatCommandWorkspace, .chatCommandModelSwitch, .chatCommandThink, .chatCommandX,
      .chatCommandSettings, .chatCommandPin, .chatCommandMeeting, .chatCommandCopy,
      .chatCommandFeedback:
      slashCommand ?? rawValue
    }
  }
}
