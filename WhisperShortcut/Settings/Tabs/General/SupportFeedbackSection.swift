//
//  SupportFeedbackSection.swift
//  WhisperShortcut
//

import SwiftUI
import AppKit

struct SupportFeedbackSection: View {
  @ObservedObject var viewModel: SettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Support & Feedback",
        systemImage: "bubble.left.and.bubble.right",
        subtitle:
          "Something not working, an idea or a question? Report it here. Your configuration goes with it, so I can reproduce the problem."
      )

      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 12) {
          // The one way to give feedback, the same window as the menu bar's "Report a Problem…".
          // It attaches the configuration, which no plain message can carry.
          Button(action: {
            viewModel.openProblemReport()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
                .opacity(0.9)

              Text("Report a Problem…")
                .font(.body)
                .fontWeight(.medium)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(SettingsConstants.cornerRadius)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Send a problem, an idea or a question to the developer, with your configuration attached. You see everything before it is sent.")
          .pointerCursorOnHover()

          // For people who just want to write: plain text, selectable, no second feedback flow.
          HStack(spacing: 4) {
            Text("Or write to")
              .foregroundColor(.secondary)
            Text(verbatim: FeedbackLinks.supportEmail)
              .textSelection(.enabled)
          }
          .font(.callout)
          .padding(.leading, 2)

          #if APP_STORE
          // App Store build only: the direct build never sends people to the App Store
          // (Magnus, 2026-11-03).
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

              Text(viewModel.data.appStoreLinkCopied ? ("Link copied!" as LocalizedStringKey) : "Share with Friends")
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
          .help(viewModel.data.appStoreLinkCopied ? ("App Store link copied to clipboard" as LocalizedStringKey) : "Copy App Store link to clipboard")
          .pointerCursorOnHover()
          #endif

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
  }
}
