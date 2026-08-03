//
//  SupportFeedbackSection.swift
//  WhisperShortcut
//

import SwiftUI
import AppKit

struct SupportFeedbackSection: View {
  @ObservedObject var viewModel: SettingsViewModel

  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var saveUsageData = true
  @State private var usageReport: String?
  @State private var isBuildingReport = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Support & Feedback",
        systemImage: "bubble.left.and.bubble.right",
        subtitle:
          "If you have feedback, if something doesn't work, or if you have suggestions for improvement, message me on WhatsApp or send an email — whichever suits you."
      )

      VStack(alignment: .leading, spacing: 20) {
        VStack(spacing: 12) {
          Button(action: {
            viewModel.openWhatsAppFeedback()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image("WhatsApp")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(0.85)

              Text("Contact me on WhatsApp")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(SettingsConstants.cornerRadius)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Contact via WhatsApp")
          .pointerCursorOnHover()

          // Sits right under WhatsApp so the alternative is visible in the same glance — someone
          // without WhatsApp should not have to hunt for a second way to reach the developer.
          Button(action: {
            viewModel.openEmailFeedback()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: "envelope.fill")
                .font(.system(size: 18))
                .foregroundColor(.blue)
                .opacity(0.85)

              Text("Email me")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(SettingsConstants.cornerRadius)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Email the developer")
          .pointerCursorOnHover()

          // Sits with the two contact channels because it is one: a report of how the app behaved
          // is feedback, just the kind nobody can type from memory. Building it does blocking file
          // I/O over up to 30 days of JSONL, so it runs off the main thread — this window must not
          // beachball on a button press.
          Button(action: {
            guard !isBuildingReport else { return }
            isBuildingReport = true
            Task.detached(priority: .userInitiated) {
              let report = UsageReport.build()
              await MainActor.run {
                isBuildingReport = false
                usageReport = report
              }
            }
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 18))
                .foregroundColor(.purple)
                .opacity(0.85)

              Text(isBuildingReport ? "Preparing report…" : "Share Usage Report")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(SettingsConstants.cornerRadius)
          }
          .buttonStyle(PlainButtonStyle())
          .disabled(!saveUsageData || isBuildingReport)
          .opacity(saveUsageData ? 1 : 0.5)
          // Disabled rather than hidden when logging is off: a feature nobody can see is a feature
          // nobody turns the toggle on for.
          .help(
            saveUsageData
              ? "See and share an anonymous summary of how you use the app"
              : "Turn on \"Save usage data\" in Improvement settings to collect this"
          )
          .pointerCursorOnHover()

          Button(action: {
            viewModel.openAppStoreReview()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: "star.fill")
                .font(.system(size: 18))
                .foregroundColor(.orange)
                .opacity(0.85)

              Text("Leave a Review")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(SettingsConstants.cornerRadius)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Leave a review on the App Store")
          .pointerCursorOnHover()

          Button(action: {
            viewModel.copyAppStoreLink()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: viewModel.data.appStoreLinkCopied ? "checkmark.circle.fill" : "link")
                .font(.system(size: 18))
                .foregroundColor(viewModel.data.appStoreLinkCopied ? .green : .blue)
                .opacity(0.85)

              Text(viewModel.data.appStoreLinkCopied ? "Link copied!" : "Share with Friends")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(SettingsConstants.cornerRadius)
          }
          .buttonStyle(PlainButtonStyle())
          .help(viewModel.data.appStoreLinkCopied ? "App Store link copied to clipboard" : "Copy App Store link to clipboard")
          .pointerCursorOnHover()

          Button(action: {
            viewModel.openGitHub()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image("GitHubMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .foregroundColor(.secondary)
                .opacity(0.85)

              Text("Open on GitHub")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(SettingsConstants.cornerRadius)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Open the WhisperShortcut repository on GitHub")
          .pointerCursorOnHover()
        }

        HStack(spacing: 16) {
          Image("me")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 64)
            .clipShape(Circle())

          VStack(alignment: .leading, spacing: 4) {
            Text("— Magnus • Developer")
              .font(.body)
              .foregroundColor(.secondary)
              .opacity(0.8)

            Text("Heidelberg, Germany 🇩🇪")
              .font(.subheadline)
              .foregroundColor(.secondary)
              .opacity(0.7)
          }

          Spacer()
        }
        .padding(.top, 12)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { usageReport != nil },
        set: { if !$0 { usageReport = nil } }
      )
    ) {
      if let report = usageReport {
        UsageReportSheet(report: report, onDismiss: { usageReport = nil })
      }
    }
  }
}
