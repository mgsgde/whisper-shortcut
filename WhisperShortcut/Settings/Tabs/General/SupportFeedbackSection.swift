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
        title: "💬 Support & Feedback",
        subtitle:
          "If you have feedback, if something doesn't work, or if you have suggestions for improvement, feel free to contact me via WhatsApp."
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
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Contact via WhatsApp")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }

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
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Leave a review on the App Store")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }

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
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help(viewModel.data.appStoreLinkCopied ? "App Store link copied to clipboard" : "Copy App Store link to clipboard")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }

          Button(action: {
            viewModel.openGitHub()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 18))
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
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Open the WhisperShortcut repository on GitHub")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }
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

            Text("Karlsruhe, Germany 🇩🇪")
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
