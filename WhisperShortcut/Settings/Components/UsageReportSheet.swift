import SwiftUI

/// Shows the usage report and offers to hand it to the developer.
///
/// The whole report is displayed verbatim, not summarised: consent to send something means having
/// seen the thing that gets sent. The send buttons hand the text to `FeedbackLinks`, which opens
/// the user's own mail or WhatsApp client with it prefilled — the app itself never transmits, which
/// is the property that lets the privacy promise stay as it is.
struct UsageReportSheet: View {
  let report: String
  let onDismiss: () -> Void

  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Usage report")
          .font(.headline)
        Text(
          "This is everything the report contains. Nothing is sent automatically — pressing a send button opens your own mail or WhatsApp with this text prefilled."
        )
        .font(.subheadline)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      ScrollView {
        Text(report)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .background(Color(NSColor.controlBackgroundColor))
      .cornerRadius(SettingsConstants.cornerRadius)

      HStack(spacing: 12) {
        Button("Cancel", action: onDismiss)
          .keyboardShortcut(.cancelAction)

        Spacer()

        Button(copied ? "Copied!" : "Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(report, forType: .string)
          copied = true
        }

        Button("Send via Email") {
          FeedbackLinks.open(.email, context: report)
          onDismiss()
        }

        Button("Send via WhatsApp") {
          FeedbackLinks.open(.whatsApp, context: report)
          onDismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560, height: 520)
  }
}
