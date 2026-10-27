import SwiftUI

/// Plain, functional review body for a `.settings` proposal: one line per change, no diff
/// styling and no editing (there is no single text to edit). Deliberately minimal — the visual
/// design of this screen is Opus 5.5's to do later; this exists so `update_settings` has
/// somewhere to show up today. See `plans/active/mcp-settings.md`.
struct MCPSettingsProposalReviewView: View {
  let items: [MCPSettingsChangeItem]
  let rationale: String
  let onAccept: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Suggested by an AI app")
        .font(.headline)

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(items, id: \.id) { item in
            Text("\(item.title): \(item.fromLabel) → \(item.toLabel)")
              .font(.body)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()

      Text(rationale)
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("Decline", action: onCancel)
        Button("Accept", action: onAccept)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 480, idealWidth: 520, minHeight: 280, idealHeight: 360)
  }
}
