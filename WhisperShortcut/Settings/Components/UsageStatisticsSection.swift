import SwiftUI

/// Wording shared by the onboarding card and the Settings section, so both promise the same thing.
enum UsageStatisticsCopy {
  static let toggleTitle = "Share anonymous usage statistics"
  static let summary =
    "Counts only — how often features are used and whether they worked. Never your words, audio, or which apps you use. No ID, no tracking. Off unless you turn it on."
  static let why = "Helps a solo developer fix what actually breaks."
  static let unavailableOffline = "Unavailable while Offline Mode is on — nothing leaves this Mac."
  static let unavailableAdmin = "Turned off by your administrator."
}

/// The opt-in switch plus "See exactly what is sent". Hidden behind an explanation while Offline
/// Mode or the administrator key forces sharing off.
struct UsageStatisticsToggle: View {
  @AppStorage(UserDefaultsKeys.telemetryEnabled) private var enabled = false
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false
  @AppStorage(UserDefaultsKeys.telemetryForceDisabled) private var forceDisabled = false
  @State private var showingPreview = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if offlineMode || forceDisabled {
        Toggle(UsageStatisticsCopy.toggleTitle, isOn: .constant(false))
          .toggleStyle(.switch)
          .font(.callout)
          .fontWeight(.semibold)
          .disabled(true)
        Text(forceDisabled ? UsageStatisticsCopy.unavailableAdmin : UsageStatisticsCopy.unavailableOffline)
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Toggle(UsageStatisticsCopy.toggleTitle, isOn: $enabled)
          .toggleStyle(.switch)
          .font(.callout)
          .fontWeight(.semibold)
          .onChange(of: enabled) { isOn in
            TelemetryService.shared.consentChanged(isOn)
          }
        Text("\(UsageStatisticsCopy.summary) \(UsageStatisticsCopy.why)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("See exactly what is sent") { showingPreview = true }
          .buttonStyle(.link)
          .font(.caption)
          .pointerCursorOnHover()
      }
    }
    .sheet(isPresented: $showingPreview) {
      UsageStatisticsPreviewSheet(onDismiss: { showingPreview = false })
    }
  }
}

/// Settings → Privacy & Permissions card.
struct UsageStatisticsSection: View {
  var body: some View {
    UsageStatisticsToggle()
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
  }
}

/// Shows the exact JSON: what is queued right now, and the last ping actually delivered. Before
/// anything was collected it shows a representative example, so the user can judge the format
/// before opting in.
struct UsageStatisticsPreviewSheet: View {
  let onDismiss: () -> Void

  private var pending: String { TelemetryService.shared.previewJSON() }
  private var lastSent: String? { TelemetryService.shared.lastSentJSON }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("What is sent")
          .font(.headline)
        Text(
          "This is the complete content, as sent. One summary per day you use the app, plus a one-time note when you pass a setup step or use a feature for the first time. The server's code is public: github.com/mgsgde/whisper-shortcut/tree/main/server/telemetry"
        )
        .font(.subheadline)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          section(title: "Queued", body: pending.isEmpty ? Self.example : pending,
                  note: pending.isEmpty ? "Nothing collected yet — this is an example of a daily summary." : nil)
          if let lastSent {
            section(title: "Last sent", body: lastSent, note: nil)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
      .background(Color(NSColor.controlBackgroundColor))
      .cornerRadius(SettingsConstants.cornerRadius)

      HStack {
        Spacer()
        Button("Done", action: onDismiss)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560, height: 560)
  }

  @ViewBuilder
  private func section(title: String, body: String, note: String?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.subheadline).fontWeight(.semibold)
      if let note {
        Text(note).font(.caption).foregroundStyle(.secondary)
      }
      Text(body)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
  }

  private static let example = """
    {
      "app" : "\(AppConstants.appVersion)",
      "build" : "appstore",
      "cohortWeek" : "2026-W40",
      "counts" : {
        "dictation.completed" : 12,
        "dictation.failed" : 1,
        "dictation.pasted" : 11
      },
      "dayIndex" : 3,
      "errors" : {
        "dictation.network" : 1
      },
      "kind" : "daily",
      "models" : {
        "transcription" : {
          "gemini-3.5-flash" : 12
        }
      },
      "os" : "26",
      "setup" : {
        "autoPaste" : false,
        "offlineWhisperModel" : false,
        "providers" : [ "gemini" ],
        "smartImprovement" : true
      },
      "v" : 1
    }
    """
}
