import SwiftUI

/// Shown when the chat, running on a light model, is about to touch the app's own configuration
/// (instructions, glossary, settings). Light models misread which rule already exists and write
/// conflicting or wrong ones, and the user only notices weeks later in their dictations. The card
/// stops the turn before the first config call and offers the one-click way out: switch to the
/// strongest model the user has a key for and send the same message again.
struct WeakModelWarningCardView: View {
  let request: WeakModelWarningRequest
  let onDecision: (WeakModelGuardDecision) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.orange)
        VStack(alignment: .leading, spacing: 4) {
          Text("Use a stronger model for this change?")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(ChatTheme.primaryText)
          message
            .font(.system(size: 13))
            .foregroundColor(ChatTheme.primaryText.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack(spacing: 8) {
        Spacer()
        Button("Continue with \(request.currentModel.displayName)") {
          onDecision(.proceed)
        }
        .keyboardShortcut(.cancelAction)
        if let suggested = request.suggestedModel {
          Button("Switch to \(suggested.displayName)") {
            onDecision(.switchModel(suggested))
          }
          .keyboardShortcut(.defaultAction)
        }
      }
      .controlSize(.small)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(ChatTheme.controlBackground)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Use a stronger model for this change?"))
  }

  private var message: Text {
    let current = request.currentModel.displayName
    guard let suggested = request.suggestedModel else {
      return Text("**\(current)** is a light model and often gets changes to your setup wrong. Pick a stronger one with `/model`, then send your message again.")
    }
    return Text("**\(current)** is a light model and often gets changes to your setup wrong: it may edit the wrong rule or miss one that is already there. Switch to **\(suggested.displayName)** and your message is sent again.")
  }
}
