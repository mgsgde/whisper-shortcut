import SwiftUI

/// Review window for a `.settings` proposal from `update_settings`: one row per change, the old
/// value struck through next to the new one, the AI app's reason above. No editing: the changes
/// are picker values, and editing them belongs in Settings. Accepting applies the whole batch at
/// once, and the batch is one entry in "Changed by AI apps", so one Undo restores all of it.
struct MCPSettingsProposalReviewView: View {
  let items: [MCPSettingsChangeItem]
  let rationale: String
  let onAccept: () -> Void
  let onCancel: () -> Void

  private var acceptTitle: String {
    items.count == 1 ? "Apply Change" : "Apply \(items.count) Changes"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Settings Change from an AI App")
          .font(.headline)
        Text("Nothing has changed yet. Accepted changes apply together.")
          .font(.callout)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !rationale.isEmpty {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "quote.opening")
            .foregroundColor(.accentColor)
          Text(rationale)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(6)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { Divider() }
            changeRow(item)
          }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
      }

      HStack(spacing: 12) {
        Button("Decline") { onCancel() }
          .keyboardShortcut(.cancelAction)
          .pointerCursorOnHover()

        Spacer()

        Text("You can undo it in Settings → Claude & AI Apps.")
          .font(.caption)
          .foregroundColor(.secondary)

        // No default-action shortcut: this window can open while the user types elsewhere, and a
        // stray Return must never change their setup.
        Button(acceptTitle) { onAccept() }
          .buttonStyle(.borderedProminent)
          .disabled(items.isEmpty)
          .pointerCursorOnHover()
      }
    }
    .padding(20)
    .frame(minWidth: 520, idealWidth: 560, minHeight: 320, idealHeight: 420)
  }

  private func changeRow(_ item: MCPSettingsChangeItem) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(item.title)
        .font(.callout)
        .fontWeight(.medium)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(item.fromLabel)
          .strikethrough()
          .foregroundColor(.secondary)
        Image(systemName: "arrow.right")
          .font(.caption)
          .foregroundColor(.secondary)
        Text(item.toLabel)
          .fontWeight(.semibold)
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
