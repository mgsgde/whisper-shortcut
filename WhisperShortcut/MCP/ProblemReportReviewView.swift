import SwiftUI

/// Review window for a `report_problem` call: an AI app found a problem in WhisperShortcut that no
/// setting can fix. Unlike a settings proposal there is nothing to diff and nothing to apply. The
/// only way out is a GitHub issue the user opens themselves, so this view's job is to make the
/// user read and redact the text first. GitHub issues are public, and the examples come from
/// their own dictations.
struct ProblemReportReviewView: View {
  @State private var title: String
  @State private var report: String
  let onSend: (_ title: String, _ report: String) -> Void
  let onDiscard: () -> Void

  init(
    title: String, report: String,
    onSend: @escaping (_ title: String, _ report: String) -> Void,
    onDiscard: @escaping () -> Void
  ) {
    self._title = State(initialValue: title)
    self._report = State(initialValue: report)
    self.onSend = onSend
    self.onDiscard = onDiscard
  }

  private var canSend: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Problem Report from an AI App")
          .font(.headline)
        Text("An AI app on this Mac found something in WhisperShortcut that no setting can fix. Nothing has been sent.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.orange)
        Text("GitHub issues are public. Remove names, patient or customer details and anything else private before you send it.")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.orange.opacity(0.10))
      .cornerRadius(6)

      VStack(alignment: .leading, spacing: 6) {
        Text("Title")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        TextField("Title", text: $title)
          .textFieldStyle(.roundedBorder)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Report (editable)")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        TextEditor(text: $report)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(4)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
          .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
          .frame(minHeight: 280)
      }

      HStack(spacing: 12) {
        Button("Discard") { onDiscard() }
          .keyboardShortcut(.cancelAction)
          .pointerCursorOnHover()

        Spacer()

        Text("Opens in your browser. You submit it there.")
          .font(.caption)
          .foregroundColor(.secondary)

        // No default-action shortcut: this window can open while the user types elsewhere, and a
        // stray Return must never send anything.
        Button("Open as GitHub Issue…") { onSend(title, report) }
          .disabled(!canSend)
          .pointerCursorOnHover()
      }
    }
    .padding(20)
    .frame(minWidth: 640, minHeight: 560)
  }
}
